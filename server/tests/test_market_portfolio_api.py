from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))

import app as app_module  # noqa: E402
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


@pytest.fixture
def mock_chain_reader(monkeypatch):
    reader = MagicMock()
    monkeypatch.setattr(app_module, "chain_reader", reader)
    return reader


def test_market_returns_chain_payload(mock_chain_reader):
    mock_chain_reader.read_market.return_value = {
        "app": "0x0000000000000000000000000000000000000abc",
        "chain": "ethereum",
        "debt_token": {"address": "0xdebt", "symbol": "USDT", "decimals": 6},
        "collaterals": [],
        "maturities": [{"timestamp": 1735689600, "label": "DEC 31", "vault": "0xvault"}],
    }
    client = app.test_client()
    response = client.get(
        "/api/market",
        query_string={"app": "0x0000000000000000000000000000000000000abc"},
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["debt_token"]["symbol"] == "USDT"
    assert payload["maturities"][0]["timestamp"] == 1735689600


def test_portfolio_returns_chain_payload(mock_chain_reader):
    mock_chain_reader.read_portfolio.return_value = {
        "address": "0x1111111111111111111111111111111111111111",
        "app": "0x0000000000000000000000000000000000000abc",
        "chain": "ethereum",
        "risk": {
            "total_debt": "0",
            "health_status": "no_debt",
        },
        "collateral": [],
        "debts": [],
        "lending": [],
        "wallet": [],
    }
    client = app.test_client()
    response = client.get(
        "/api/portfolio",
        query_string={
            "app": "0x0000000000000000000000000000000000000abc",
            "address": "0x1111111111111111111111111111111111111111",
        },
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["risk"]["health_status"] == "no_debt"


def test_market_maps_rpc_failure(mock_chain_reader):
    mock_chain_reader.read_market.side_effect = ConnectionError("RPC unavailable")
    client = app.test_client()
    response = client.get(
        "/api/market",
        query_string={"app": "0x0000000000000000000000000000000000000abc"},
    )
    assert response.status_code == 503
