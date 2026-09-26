from __future__ import annotations

import logging
import re
from typing import Any

from flask import Flask, jsonify, request
from flask_cors import CORS
from web3 import Web3

from config import SETTINGS
from db import Database
from sync import ChainSyncer
from worker import SyncWorker

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)

app = Flask(__name__)
CORS(app, resources={r"/api/*": {"origins": "*"}})

database = Database(SETTINGS.orderbook_db)
syncer = ChainSyncer(database)
syncer.ensure_apps(SETTINGS.aquaterm_apps)
worker = SyncWorker(
    database,
    syncer,
    poll_interval=SETTINGS.sync_interval_seconds,
)


def _parse_int(name: str, default: int, *, minimum: int = 1, maximum: int | None = None) -> int:
    raw = request.args.get(name, default)
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid {name}") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be <= {maximum}")
    return value


def _parse_bool(name: str, default: bool = False) -> bool:
    raw = request.args.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _validate_address(value: str) -> str:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value or ""):
        raise ValueError("Invalid app address")
    return Web3.to_checksum_address(value).lower()


@app.before_request
def _ensure_worker() -> None:
    if app.config.get("TESTING"):
        return
    if not worker.is_alive:
        worker.start()


@app.get("/api/health")
def health() -> Any:
    apps = database.list_apps()
    return jsonify(
        {
            "status": "ok",
            "sync_worker_alive": worker.is_alive,
            "apps": apps,
        }
    )


@app.get("/api/orderbook")
def orderbook() -> Any:
    try:
        app_address = _validate_address(request.args.get("app", ""))
        chain = (request.args.get("chain") or "ethereum").strip().lower()
        maturity = _parse_int("maturity", 0, minimum=1)
        sell_page = _parse_int("sell_page", 1, minimum=1)
        buy_page = _parse_int("buy_page", 1, minimum=1)
        sell_limit = _parse_int("sell_limit", 50, minimum=1, maximum=200)
        buy_limit = _parse_int("buy_limit", 50, minimum=1, maximum=200)
        include_expired = _parse_bool("include_expired", False)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    registered = database.get_app(app_address, chain)
    if registered is None:
        return jsonify(
            {
                "error": "App is not registered for sync",
                "hint": "Add AQUATERM_APPS=address:chain:from_block to .env",
            }
        ), 404

    sell_items, sell_total = database.list_sell_orders(
        app_address,
        chain,
        maturity,
        page=sell_page,
        limit=sell_limit,
        include_expired=include_expired,
    )
    buy_items, buy_total = database.list_buy_orders(
        app_address,
        chain,
        maturity,
        page=buy_page,
        limit=buy_limit,
        include_expired=include_expired,
    )

    return jsonify(
        {
            "app": app_address,
            "chain": chain,
            "maturity": maturity,
            "sync": {
                "from_block": registered["from_block"],
                "last_synced_block": registered["last_synced_block"],
                "last_refresh_at": registered["last_refresh_at"],
            },
            "sell": {
                "items": sell_items,
                "page": sell_page,
                "limit": sell_limit,
                "total": sell_total,
                "pages": (sell_total + sell_limit - 1) // sell_limit if sell_total else 0,
            },
            "buy": {
                "items": buy_items,
                "page": buy_page,
                "limit": buy_limit,
                "total": buy_total,
                "pages": (buy_total + buy_limit - 1) // buy_limit if buy_total else 0,
            },
        }
    )


def main() -> None:
    syncer.ensure_apps(SETTINGS.aquaterm_apps)
    worker.start()
    app.run(host="0.0.0.0", port=SETTINGS.port, debug=SETTINGS.flask_debug)


if __name__ == "__main__":
    main()
