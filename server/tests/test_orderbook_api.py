from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))

from app import app, database, worker  # noqa: E402


@pytest.fixture(autouse=True)
def _fresh_db(tmp_path, monkeypatch):
    db_path = tmp_path / "orderbook.db"
    monkeypatch.setenv("ORDERBOOK_DB", str(db_path))
    database.close()
    database.__init__(db_path)
    app.config["TESTING"] = True
    app_addr = "0x0000000000000000000000000000000000000abc"
    database.upsert_app(app_addr, "ethereum", 100, last_synced_block=99)
    yield
    worker.stop(timeout=1)
    database.close()


def _touch_maturity(maturity: int = 1735689600, *, block_ts: int | None = None) -> None:
    import time

    database.touch_maturity_sync(
        "0x0000000000000000000000000000000000000abc",
        "ethereum",
        maturity,
        int(time.time()) if block_ts is None else block_ts,
    )


def _seed_orders() -> None:
    _touch_maturity()
    database.upsert_borrow_order(
        {
            "app_address": "0x0000000000000000000000000000000000000abc",
            "chain": "ethereum",
            "order_id": 1,
            "borrower": "0x1111111111111111111111111111111111111111",
            "maturity": 1735689600,
            "deadline": int(time.time()) + 3600,
            "face_amount": "500",
            "min_debt_token_out": "450",
            "ltv_bps": 6000,
            "collateral_id": 0,
            "filled_face": "0",
            "cancelled": 0,
            "created_block": 101,
            "quote_num": "450",
            "quote_den": "500",
        }
    )
    database.upsert_borrow_order(
        {
            "app_address": "0x0000000000000000000000000000000000000abc",
            "chain": "ethereum",
            "order_id": 2,
            "borrower": "0x2222222222222222222222222222222222222222",
            "maturity": 1735689600,
            "deadline": int(time.time()) + 3600,
            "face_amount": "500",
            "min_debt_token_out": "480",
            "ltv_bps": 6000,
            "collateral_id": 0,
            "filled_face": "0",
            "cancelled": 0,
            "created_block": 102,
            "quote_num": "480",
            "quote_den": "500",
        }
    )
    database.upsert_supply_order(
        {
            "app_address": "0x0000000000000000000000000000000000000abc",
            "chain": "ethereum",
            "order_id": 10,
            "supplier": "0x3333333333333333333333333333333333333333",
            "maturity": 1735689600,
            "deadline": int(time.time()) + 3600,
            "debt_token_in": "480",
            "min_term_out": "500",
            "filled_debt_token": "0",
            "cancelled": 0,
            "created_block": 103,
            "quote_num": "500",
            "quote_den": "480",
        }
    )
    database.upsert_supply_order(
        {
            "app_address": "0x0000000000000000000000000000000000000abc",
            "chain": "ethereum",
            "order_id": 11,
            "supplier": "0x4444444444444444444444444444444444444444",
            "maturity": 1735689600,
            "deadline": int(time.time()) + 3600,
            "debt_token_in": "480",
            "min_term_out": "490",
            "filled_debt_token": "0",
            "cancelled": 0,
            "created_block": 104,
            "quote_num": "490",
            "quote_den": "480",
        }
    )


def test_orderbook_sorted_and_paginated():
    _seed_orders()
    client = app.test_client()
    response = client.get(
        "/api/orderbook",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "maturity": 1735689600,
            "sell_limit": 1,
            "sell_page": 1,
            "buy_limit": 1,
            "buy_page": 1,
        },
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["sell"]["total"] == 2
    assert payload["buy"]["total"] == 2
    assert payload["sell"]["items"][0]["order_id"] == 1
    assert payload["buy"]["items"][0]["order_id"] == 10
    assert payload["sync"]["status"] == "ok"


def test_unknown_app_returns_404():
    client = app.test_client()
    response = client.get(
        "/api/orderbook",
        query_string={
            "app": "0x0000000000000000000000000000000000000def",
            "maturity": 1735689600,
        },
    )
    assert response.status_code == 404
