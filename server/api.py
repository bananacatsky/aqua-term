"""Read-only AquaTerm query functions used by the Flask routes.

These can be called without starting the HTTP server.
"""
from __future__ import annotations

from typing import Any

from config import SETTINGS, AppConfig
from chain import ChainReader
from db import Database


class AppNotRegistered(LookupError):
    def __init__(self, app_address: str, chain: str):
        super().__init__("App is not registered for sync")
        self.app_address = app_address
        self.chain = chain


def app_config_for(app_address: str, chain: str) -> AppConfig | None:
    for item in SETTINGS.aquaterm_apps:
        if item.address == app_address and item.chain == chain:
            return item
    return None


def require_app(database: Database, app_address: str, chain: str) -> dict[str, Any]:
    registered = database.get_app(app_address, chain)
    if registered is None:
        raise AppNotRegistered(app_address, chain)
    return registered


def paginated(items: list[Any], total: int, page: int, limit: int) -> dict[str, Any]:
    return {
        "items": items,
        "page": page,
        "limit": limit,
        "total": total,
        "pages": (total + limit - 1) // limit if total else 0,
    }


def get_market(
    database: Database,
    chain_reader: ChainReader,
    app_address: str,
    chain: str,
) -> dict[str, Any]:
    require_app(database, app_address, chain)
    return chain_reader.read_market(
        app_address,
        chain,
        app_config=app_config_for(app_address, chain),
    )


def get_portfolio(
    database: Database,
    chain_reader: ChainReader,
    app_address: str,
    chain: str,
    address: str,
    *,
    include_wallet: bool = True,
) -> dict[str, Any]:
    require_app(database, app_address, chain)
    return chain_reader.read_portfolio(
        app_address,
        chain,
        address,
        app_config=app_config_for(app_address, chain),
        include_wallet=include_wallet,
    )


def get_orders(
    database: Database,
    app_address: str,
    chain: str,
    maker: str,
    *,
    borrow_page: int = 1,
    supply_page: int = 1,
    borrow_limit: int = 50,
    supply_limit: int = 50,
    include_expired: bool = False,
    include_closed: bool = False,
) -> dict[str, Any]:
    require_app(database, app_address, chain)
    borrow_items, borrow_total = database.list_maker_borrow_orders(
        app_address,
        chain,
        maker,
        page=borrow_page,
        limit=borrow_limit,
        include_expired=include_expired,
        include_closed=include_closed,
    )
    supply_items, supply_total = database.list_maker_supply_orders(
        app_address,
        chain,
        maker,
        page=supply_page,
        limit=supply_limit,
        include_expired=include_expired,
        include_closed=include_closed,
    )
    return {
        "app": app_address,
        "chain": chain,
        "maker": maker,
        "borrow": paginated(borrow_items, borrow_total, borrow_page, borrow_limit),
        "supply": paginated(supply_items, supply_total, supply_page, supply_limit),
    }


def get_orderbook(
    database: Database,
    app_address: str,
    chain: str,
    maturity: int,
    *,
    sell_page: int = 1,
    buy_page: int = 1,
    sell_limit: int = 50,
    buy_limit: int = 50,
    include_expired: bool = False,
) -> dict[str, Any]:
    registered = require_app(database, app_address, chain)
    fresh, maturity_sync = database.maturity_sync_is_fresh(
        app_address,
        chain,
        maturity,
        SETTINGS.sync_max_age_seconds,
    )
    if maturity_sync is None:
        sync_status = "pending"
        last_synced_at = None
    elif not fresh:
        sync_status = "stale"
        last_synced_at = maturity_sync["last_synced_at"]
    else:
        sync_status = "ok"
        last_synced_at = maturity_sync["last_synced_at"]

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
    return {
        "app": app_address,
        "chain": chain,
        "maturity": maturity,
        "sync": {
            "status": sync_status,
            "from_block": registered["from_block"],
            "last_synced_block": registered["last_synced_block"],
            "last_refresh_at": registered["last_refresh_at"],
            "last_synced_at": last_synced_at,
            "max_age_seconds": SETTINGS.sync_max_age_seconds,
        },
        "sell": paginated(sell_items, sell_total, sell_page, sell_limit),
        "buy": paginated(buy_items, buy_total, buy_page, buy_limit),
    }
