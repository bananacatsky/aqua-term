from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))

from app import app, database, worker  # noqa: E402
from config import SETTINGS  # noqa: E402


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


def test_mark_maturities_synced_touches_indexed_markets():
    from sync import ChainSyncer

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
    ChainSyncer(database).mark_maturities_synced(
        "0x0000000000000000000000000000000000000abc",
        "ethereum",
        int(time.time()),
    )
    fresh, row = database.maturity_sync_is_fresh(
        "0x0000000000000000000000000000000000000abc",
        "ethereum",
        1735689600,
        3600,
    )
    assert fresh
    assert row is not None


def test_orderbook_returns_empty_when_unsynced():
    client = app.test_client()
    response = client.get(
        "/api/orderbook",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "maturity": 1735689600,
        },
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["sync"]["status"] == "pending"
    assert payload["sell"]["items"] == []
    assert payload["buy"]["items"] == []


def test_orderbook_marks_stale_maturity():
    stale_at = int(time.time()) - SETTINGS.sync_max_age_seconds - 60
    database.touch_maturity_sync(
        "0x0000000000000000000000000000000000000abc",
        "ethereum",
        1735689600,
        stale_at,
    )
    client = app.test_client()
    response = client.get(
        "/api/orderbook",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "maturity": 1735689600,
        },
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["sync"]["status"] == "stale"
    assert payload["sell"]["items"] == []
    assert payload["buy"]["items"] == []
