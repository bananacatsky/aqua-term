from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

_SERVER_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _SERVER_DIR.parent

for env_path in (_SERVER_DIR / ".env", _REPO_ROOT / ".env", _REPO_ROOT.parent / "w" / ".env"):
    if env_path.is_file():
        load_dotenv(env_path)


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class AppConfig:
    address: str
    chain: str
    from_block: int
    maturities: tuple[int, ...] = ()


def parse_csv(raw: str) -> tuple[str, ...]:
    return tuple(x.strip() for x in raw.split(",") if x.strip())


def parse_apps(raw: str) -> tuple[AppConfig, ...]:
    apps: list[AppConfig] = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        parts = item.split(":")
        if len(parts) not in (3, 4):
            raise ValueError(
                f"Invalid AQUATERM_APPS entry {item!r}; "
                "expected address:chain:from_block[:maturity_ts,maturity_ts,...]"
            )
        address, chain, from_block = parts[0], parts[1], parts[2]
        maturities: tuple[int, ...] = ()
        if len(parts) == 4 and parts[3].strip():
            maturities = tuple(int(x.strip()) for x in parts[3].split(",") if x.strip())
        apps.append(
            AppConfig(address.lower(), chain.lower(), int(from_block), maturities)
        )
    return tuple(apps)


@dataclass(frozen=True)
class Settings:
    eth_rpc_url: str = os.getenv("ETH_RPC_URL", "https://ethereum-rpc.publicnode.com")
    base_rpc_url: str = os.getenv("BASE_RPC_URL", "https://mainnet.base.org")
    optimism_rpc_url: str = os.getenv(
        "OPTIMISM_RPC_URL", "https://mainnet.optimism.io"
    )
    arbitrum_rpc_url: str = os.getenv(
        "ARBITRUM_RPC_URL", "https://arb1.arbitrum.io/rpc"
    )
    http_timeout: float = float(os.getenv("HTTP_TIMEOUT", "30"))
    port: int = int(os.getenv("PORT", "5001"))
    flask_debug: bool = env_bool("FLASK_DEBUG", False)
    orderbook_db: str = os.getenv("ORDERBOOK_DB", str(_SERVER_DIR / "orderbook.db"))
    sync_interval_seconds: float = float(os.getenv("SYNC_INTERVAL_SECONDS", "12"))
    sync_block_chunk: int = int(os.getenv("SYNC_BLOCK_CHUNK", "2000"))
    sync_max_age_seconds: int = int(os.getenv("SYNC_MAX_AGE_SECONDS", str(30 * 24 * 3600)))
    refresh_open_orders: bool = env_bool("REFRESH_OPEN_ORDERS", True)
    # Server-side display prices in USD cents. Override from the deployment env
    # or replace with an oracle/price-feed adapter for production.
    usdt_usd_cents: int = int(os.getenv("USDT_USD_CENTS", "100"))
    weth_usd_cents: int = int(os.getenv("WETH_USD_CENTS", "356097"))
    wbtc_usd_cents: int = int(os.getenv("WBTC_USD_CENTS", "6581833"))
    cors_origins: tuple[str, ...] = parse_csv(
        os.getenv(
            "CORS_ORIGINS",
            "https://bananacatsky.github.io",
        )
    )
    aquaterm_apps: tuple[AppConfig, ...] = (
        parse_apps(os.getenv("AQUATERM_APPS", "")) if os.getenv("AQUATERM_APPS") else ()
    )


SETTINGS = Settings()

EVM_RPC_URLS = {
    "ethereum": SETTINGS.eth_rpc_url,
    "eth": SETTINGS.eth_rpc_url,
    "mainnet": SETTINGS.eth_rpc_url,
    "base": SETTINGS.base_rpc_url,
    "optimism": SETTINGS.optimism_rpc_url,
    "op": SETTINGS.optimism_rpc_url,
    "arbitrum": SETTINGS.arbitrum_rpc_url,
    "arb": SETTINGS.arbitrum_rpc_url,
}

# Approximate block time in seconds per chain (for rolling sync window).
CHAIN_BLOCK_TIME_SECONDS = {
    "ethereum": 12.0,
    "eth": 12.0,
    "mainnet": 12.0,
    "base": 2.0,
    "optimism": 2.0,
    "op": 2.0,
    "arbitrum": 0.25,
    "arb": 0.25,
}
