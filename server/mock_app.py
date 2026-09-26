"""Deterministic mock of the read-only AquaTerm API.

Run with: python server/mock_app.py
The routes and response shapes intentionally match server/app.py.
"""
from __future__ import annotations

import math
import time
from datetime import datetime, timezone
from typing import Any

from flask import Flask, jsonify, request

try:
    from flask_cors import CORS
except ModuleNotFoundError:  # Keep the standalone mock usable without full server deps.
    CORS = None

app = Flask(__name__)
if CORS is not None:
    CORS(app, resources={r"/api/*": {"origins": "*"}})
else:
    @app.after_request
    def add_cors_headers(response):
        if request.path.startswith("/api/"):
            response.headers["Access-Control-Allow-Origin"] = "*"
            response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
            response.headers["Access-Control-Allow-Headers"] = "Content-Type"
        return response

MOCK_APP = "0x0000000000000000000000000000000000000abc"
MOCK_USER = "0x1111111111111111111111111111111111111111"
NOW = int(time.time())
MATURITIES = [
    (1793318400, "OCT 30", "0x0000000000000000000000000000000000000101"),
    (1795996800, "NOV 30", "0x0000000000000000000000000000000000000102"),
    (1798675200, "DEC 31", "0x0000000000000000000000000000000000000103"),
    (1801353600, "JAN 31", "0x0000000000000000000000000000000000000104"),
]

TOKENS = {
    "usdt": {"address": "0x0000000000000000000000000000000000000201", "symbol": "USDT", "name": "Mock Tether USD", "decimals": 6},
    "weth": {"address": "0x0000000000000000000000000000000000000202", "symbol": "WETH", "name": "Wrapped Ether", "decimals": 18},
    "wbtc": {"address": "0x0000000000000000000000000000000000000203", "symbol": "WBTC", "name": "Wrapped Bitcoin", "decimals": 8},
}


def _app() -> str:
    return (request.args.get("app") or MOCK_APP).lower()


def _chain() -> str:
    return (request.args.get("chain") or "ethereum").lower()


def _page(items: list[dict[str, Any]], page: int = 1, limit: int = 50) -> dict[str, Any]:
    start = (page - 1) * limit
    selected = items[start : start + limit]
    return {"items": selected, "page": page, "limit": limit, "total": len(items), "pages": math.ceil(len(items) / limit) if items else 0}


def _orderbook_items(maturity: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    deadline = NOW + 7 * 24 * 60 * 60
    # “sell” is the borrow side; “buy” is the supply side, like server/db.py.
    sells = [
        {"order_id": 12, "side": "sell", "maker": "0x2222222222222222222222222222222222222222", "maturity": maturity, "deadline": deadline, "face_amount": "500000000", "filled_face": "0", "remaining_face": "500000000", "min_debt_token_out": "480000000", "ltv_bps": 6000, "collateral_id": 0, "cancelled": False, "quote": {"num": "480000000", "den": "500000000"}, "quote_rate": "0.96"},
        {"order_id": 13, "side": "sell", "maker": "0x3333333333333333333333333333333333333333", "maturity": maturity, "deadline": deadline, "face_amount": "780000000", "filled_face": "0", "remaining_face": "780000000", "min_debt_token_out": "700000000", "ltv_bps": 6500, "collateral_id": 1, "cancelled": False, "quote": {"num": "700000000", "den": "780000000"}, "quote_rate": "0.8974358974358975"},
    ]
    buys = [
        {"order_id": 7, "side": "buy", "maker": "0x4444444444444444444444444444444444444444", "maturity": maturity, "deadline": deadline, "debt_token_in": "500000000", "filled_debt_token": "0", "remaining_debt_token": "500000000", "min_term_out": "540000000", "cancelled": False, "quote": {"num": "540000000", "den": "500000000"}, "quote_rate": "1.08"},
        {"order_id": 8, "side": "buy", "maker": "0x5555555555555555555555555555555555555555", "maturity": maturity, "deadline": deadline, "debt_token_in": "700000000", "filled_debt_token": "0", "remaining_debt_token": "700000000", "min_term_out": "774000000", "cancelled": False, "quote": {"num": "774000000", "den": "700000000"}, "quote_rate": "1.1057142857142858"},
    ]
    return sells, buys


@app.get("/api/health")
def health() -> Any:
    return jsonify({"status": "ok", "mode": "mock", "sync_worker_alive": False, "apps": [{"address": MOCK_APP, "chain": "ethereum", "from_block": 21000000, "last_synced_block": 21000420, "last_refresh_at": NOW}]})


@app.get("/api/market")
def market() -> Any:
    maturities = [{"timestamp": ts, "label": label, "vault": vault, "symbol": f"aquaUSDT-{label}", "name": f"AquaTerm USDT {label}"} for ts, label, vault in MATURITIES]
    collaterals = [
        {"id": 0, **TOKENS["weth"], "max_borrow_ltv_bps": 7000, "liquidation_ltv_bps": 8000, "liquidation_discount_bps": 700},
        {"id": 1, **TOKENS["wbtc"], "max_borrow_ltv_bps": 6500, "liquidation_ltv_bps": 7500, "liquidation_discount_bps": 800},
    ]
    return jsonify({"app": _app(), "chain": _chain(), "debt_token": TOKENS["usdt"], "collaterals": collaterals, "maturities": maturities})


@app.get("/api/portfolio")
def portfolio() -> Any:
    address = (request.args.get("address") or MOCK_USER).lower()
    market_payload = market().get_json()
    maturity = MATURITIES[2]
    return jsonify({
        "address": address, "app": _app(), "chain": _chain(), "debt_token": TOKENS["usdt"],
        "wallet_value_usd_cents": "274099", "risk": {"total_debt": "1860000000", "collateral_value": "3840210000", "health_factor_wad": "1460000000000000000", "health_factor": "1.46", "health_status": "healthy", "health_message": "Your position is currently healthy.", "risk_percent": 48.4, "current_ltv_bps": 4840, "max_borrow_ltv_bps": 7000, "liquidation_ltv_bps": 8000},
        "collateral": [
            {"id": 0, "token": TOKENS["weth"], "amount": "820000000000000000", "max_borrow_ltv_bps": 7000, "liquidation_ltv_bps": 8000},
            {"id": 1, "token": TOKENS["wbtc"], "amount": "1400000", "max_borrow_ltv_bps": 6500, "liquidation_ltv_bps": 7500},
        ],
        "debts": [{"maturity": maturity[0], "label": maturity[1], "vault": maturity[2], "face_debt": "500000000", "written_down": "0"}, {"maturity": MATURITIES[3][0], "label": MATURITIES[3][1], "vault": MATURITIES[3][2], "face_debt": "1360000000", "written_down": "0"}],
        "lending": [{"maturity": maturity[0], "label": maturity[1], "vault": maturity[2], "symbol": "aquaUSDT-DEC 31", "shares": "480000000", "assets": "500000000", "redeemable_shares": "192000000", "redeemable_assets": "200000000"}],
        "wallet": [{"token": TOKENS["usdt"], "amount": "1242180000"}, {"token": TOKENS["weth"], "amount": "310000000000000000"}, {"token": TOKENS["wbtc"], "amount": "600000"}],
    })


@app.get("/api/orderbook")
def orderbook() -> Any:
    maturity = int(request.args.get("maturity") or MATURITIES[0][0])
    sells, buys = _orderbook_items(maturity)
    return jsonify({"app": _app(), "chain": _chain(), "maturity": maturity, "sync": {"from_block": 21000000, "last_synced_block": 21000420, "last_refresh_at": NOW, "last_synced_at": NOW, "max_age_seconds": 2592000}, "sell": _page(sells), "buy": _page(buys)})


@app.get("/api/orders")
def orders() -> Any:
    sells, buys = _orderbook_items(MATURITIES[2][0])
    return jsonify({"app": _app(), "chain": _chain(), "maker": (request.args.get("maker") or MOCK_USER).lower(), "borrow": _page(sells), "supply": _page(buys)})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002, debug=True)
