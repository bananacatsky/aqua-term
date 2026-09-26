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


def test_orderbook_rejects_unsynced_maturity():
    client = app.test_client()
    response = client.get(
        "/api/orderbook",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "maturity": 1735689600,
        },
    )
    assert response.status_code == 503
    assert "not been synced" in response.get_json()["error"]


def test_orderbook_rejects_stale_maturity():
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
    assert response.status_code == 503
    assert response.get_json()["error"] == "Sync data is stale"
