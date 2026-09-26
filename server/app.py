from __future__ import annotations

import logging
import re
from typing import Any

from flask import Flask, jsonify, request
from flask_cors import CORS
from web3 import Web3

from api import AppNotRegistered, get_market, get_orderbook, get_orders, get_portfolio
from config import SETTINGS
from chain import ChainReader
from db import Database
from sync import ChainSyncer
from worker import SyncWorker

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)


_LOCAL_FRONTEND_ORIGINS = (
    "http://127.0.0.1:5173",
    "http://localhost:5173",
    "http://127.0.0.1:4173",
    "http://localhost:4173",
)


def _cors_origins() -> list[str] | str:
    if len(SETTINGS.cors_origins) == 1 and SETTINGS.cors_origins[0] == "*":
        return "*"
    origins = list(SETTINGS.cors_origins)
    for origin in _LOCAL_FRONTEND_ORIGINS:
        if origin not in origins:
            origins.append(origin)
    return origins


app = Flask(__name__)
CORS(app, resources={r"/api/*": {"origins": _cors_origins()}})

database = Database(SETTINGS.orderbook_db)
syncer = ChainSyncer(database)
syncer.ensure_apps(SETTINGS.aquaterm_apps)
worker = SyncWorker(
    database,
    syncer,
    poll_interval=SETTINGS.sync_interval_seconds,
)
chain_reader = ChainReader(database)


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


def _validate_address(value: str, *, field: str = "address") -> str:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value or ""):
        raise ValueError(f"Invalid {field}")
    return Web3.to_checksum_address(value).lower()


def _not_registered(app_address: str, chain: str) -> tuple[Any, int]:
    return jsonify(
        {
            "error": "App is not registered for sync",
            "hint": "Add AQUATERM_APPS=address:chain:from_block to .env",
            "app": app_address,
            "chain": chain,
        }
    ), 404


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


@app.get("/api/market")
def market() -> Any:
    try:
        app_address = _validate_address(request.args.get("app", ""), field="app address")
        chain = (request.args.get("chain") or "ethereum").strip().lower()
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    try:
        payload = get_market(database, chain_reader, app_address, chain)
    except AppNotRegistered:
        return _not_registered(app_address, chain)
    except ConnectionError as exc:
        return jsonify({"error": str(exc)}), 503
    except Exception:
        logging.exception("Failed reading market for %s on %s", app_address, chain)
        return jsonify({"error": "Failed to read market data from chain"}), 502

    return jsonify(payload)


@app.get("/api/portfolio")
def portfolio() -> Any:
    try:
        app_address = _validate_address(request.args.get("app", ""), field="app address")
        user_address = _validate_address(
            request.args.get("address", ""), field="address"
        )
        chain = (request.args.get("chain") or "ethereum").strip().lower()
        include_wallet = _parse_bool("include_wallet", True)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    try:
        payload = get_portfolio(
            database,
            chain_reader,
            app_address,
            chain,
            user_address,
            include_wallet=include_wallet,
        )
    except AppNotRegistered:
        return _not_registered(app_address, chain)
    except ConnectionError as exc:
        return jsonify({"error": str(exc)}), 503
    except Exception:
        logging.exception(
            "Failed reading portfolio for %s on %s", user_address, chain
        )
        return jsonify({"error": "Failed to read portfolio data from chain"}), 502

    return jsonify(payload)


@app.get("/api/orders")
def orders() -> Any:
    try:
        app_address = _validate_address(request.args.get("app", ""), field="app address")
        maker = _validate_address(request.args.get("maker", ""), field="maker")
        chain = (request.args.get("chain") or "ethereum").strip().lower()
        borrow_page = _parse_int("borrow_page", 1, minimum=1)
        supply_page = _parse_int("supply_page", 1, minimum=1)
        borrow_limit = _parse_int("borrow_limit", 50, minimum=1, maximum=200)
        supply_limit = _parse_int("supply_limit", 50, minimum=1, maximum=200)
        include_expired = _parse_bool("include_expired", False)
        include_closed = _parse_bool("include_closed", False)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    try:
        payload = get_orders(
            database,
            app_address,
            chain,
            maker,
            borrow_page=borrow_page,
            supply_page=supply_page,
            borrow_limit=borrow_limit,
            supply_limit=supply_limit,
            include_expired=include_expired,
            include_closed=include_closed,
        )
    except AppNotRegistered:
        return _not_registered(app_address, chain)

    return jsonify(payload)


@app.get("/api/orderbook")
def orderbook() -> Any:
    try:
        app_address = _validate_address(request.args.get("app", ""), field="app address")
        chain = (request.args.get("chain") or "ethereum").strip().lower()
        maturity = _parse_int("maturity", 0, minimum=1)
        sell_page = _parse_int("sell_page", 1, minimum=1)
        buy_page = _parse_int("buy_page", 1, minimum=1)
        sell_limit = _parse_int("sell_limit", 50, minimum=1, maximum=200)
        buy_limit = _parse_int("buy_limit", 50, minimum=1, maximum=200)
        include_expired = _parse_bool("include_expired", False)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    try:
        payload = get_orderbook(
            database,
            app_address,
            chain,
            maturity,
            sell_page=sell_page,
            buy_page=buy_page,
            sell_limit=sell_limit,
            buy_limit=buy_limit,
            include_expired=include_expired,
        )
    except AppNotRegistered:
        return _not_registered(app_address, chain)

    return jsonify(payload)


def main() -> None:
    syncer.ensure_apps(SETTINGS.aquaterm_apps)
    worker.start()
    app.run(host="0.0.0.0", port=SETTINGS.port, debug=SETTINGS.flask_debug)


if __name__ == "__main__":
    main()
