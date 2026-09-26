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


def _seed_maker_orders() -> None:
    maker = "0x1111111111111111111111111111111111111111"
    other = "0x2222222222222222222222222222222222222222"
    app_addr = "0x0000000000000000000000000000000000000abc"
    deadline = int(time.time()) + 3600
    database.upsert_borrow_order(
        {
            "app_address": app_addr,
            "chain": "ethereum",
            "order_id": 1,
            "borrower": maker,
            "maturity": 1735689600,
            "deadline": deadline,
            "face_amount": "500",
            "min_debt_token_out": "450",
            "ltv_bps": 6000,
            "collateral_id": 0,
            "filled_face": "100",
            "cancelled": 0,
            "created_block": 101,
            "quote_num": "450",
            "quote_den": "500",
        }
    )
    database.upsert_borrow_order(
        {
            "app_address": app_addr,
            "chain": "ethereum",
            "order_id": 2,
            "borrower": other,
            "maturity": 1735689600,
            "deadline": deadline,
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
            "app_address": app_addr,
            "chain": "ethereum",
            "order_id": 10,
            "supplier": maker,
            "maturity": 1738368000,
            "deadline": deadline,
            "debt_token_in": "480",
            "min_term_out": "500",
            "filled_debt_token": "0",
            "cancelled": 0,
            "created_block": 103,
            "quote_num": "500",
            "quote_den": "480",
        }
    )


def test_orders_filters_by_maker():
    _seed_maker_orders()
    client = app.test_client()
    response = client.get(
        "/api/orders",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "maker": "0x1111111111111111111111111111111111111111",
        },
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["borrow"]["total"] == 1
    assert payload["supply"]["total"] == 1
    assert payload["borrow"]["items"][0]["order_id"] == 1
    assert payload["borrow"]["items"][0]["remaining_face"] == "400"
    assert payload["supply"]["items"][0]["order_id"] == 10


def test_orders_rejects_unknown_app():
    client = app.test_client()
    response = client.get(
        "/api/orders",
        query_string={
            "app": "0x0000000000000000000000000000000000000def",
            "maker": "0x1111111111111111111111111111111111111111",
        },
    )
    assert response.status_code == 404
