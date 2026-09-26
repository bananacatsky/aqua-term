from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from web3 import Web3
from web3.contract import Contract

from config import SETTINGS, AppConfig
from db import Database
from sync import load_contract, make_web3

log = logging.getLogger(__name__)

_WAD = 10**18

_APP_ABI_PATH = Path(__file__).with_name("abi.json")
_VAULT_ABI_PATH = Path(__file__).with_name("vault_abi.json")
_ERC20_ABI_PATH = Path(__file__).with_name("erc20_abi.json")


def _load_abi(path: Path) -> list[dict[str, Any]]:
    return json.loads(path.read_text())


def _erc20_contract(w3: Web3, address: str) -> Contract:
    return w3.eth.contract(
        address=Web3.to_checksum_address(address),
        abi=_load_abi(_ERC20_ABI_PATH),
    )


def _vault_contract(w3: Web3, address: str) -> Contract:
    return w3.eth.contract(
        address=Web3.to_checksum_address(address),
        abi=_load_abi(_VAULT_ABI_PATH),
    )


def _token_metadata(w3: Web3, address: str) -> dict[str, Any]:
    token = _erc20_contract(w3, address)
    try:
        symbol = token.functions.symbol().call()
    except Exception:
        symbol = ""
    try:
        decimals = int(token.functions.decimals().call())
    except Exception:
        decimals = 18
    try:
        name = token.functions.name().call()
    except Exception:
        name = symbol
    return {
        "address": address.lower(),
        "symbol": symbol,
        "name": name,
        "decimals": decimals,
    }


def _maturity_label(timestamp: int) -> str:
    dt = datetime.fromtimestamp(timestamp, tz=timezone.utc)
    return dt.strftime("%b %d").upper()


def _health_factor_display(health_wad: int, total_debt: int) -> str | None:
    if total_debt == 0:
        return None
    if health_wad >= 2**256 - 1:
        return None
    return f"{health_wad / _WAD:.2f}"


def resolve_maturities(
    database: Database,
    app_config: AppConfig | None,
    app_address: str,
    chain: str,
) -> list[int]:
    configured: list[int] = []
    if app_config is not None and app_config.maturities:
        configured = list(app_config.maturities)
    indexed = database.list_maturities(app_address, chain)
    merged = sorted(set(configured) | set(indexed))
    return merged


@dataclass(frozen=True)
class ChainReader:
    database: Database

    def read_market(
        self,
        app_address: str,
        chain: str,
        *,
        app_config: AppConfig | None = None,
    ) -> dict[str, Any]:
        w3 = make_web3(chain)
        if not w3.is_connected():
            raise ConnectionError(f"RPC unavailable for chain {chain}")

        contract = load_contract(w3, app_address)
        debt_token_address = contract.functions.debtToken().call()
        debt_token = _token_metadata(w3, debt_token_address)

        n_collateral = int(contract.functions.N_COLLATERAL().call())
        collaterals: list[dict[str, Any]] = []
        for collateral_id in range(n_collateral):
            token_addr, max_borrow, liq_ltv, liq_discount = (
                contract.functions.collateralConfigs(collateral_id).call()
            )
            token = _token_metadata(w3, token_addr)
            collaterals.append(
                {
                    "id": collateral_id,
                    **token,
                    "max_borrow_ltv_bps": int(max_borrow),
                    "liquidation_ltv_bps": int(liq_ltv),
                    "liquidation_discount_bps": int(liq_discount),
                }
            )

        maturities: list[dict[str, Any]] = []
        for maturity_ts in resolve_maturities(
            self.database, app_config, app_address, chain
        ):
            vault_address = contract.functions.vaultForMaturity(maturity_ts).call()
            if int(vault_address, 16) == 0:
                continue
            vault = _vault_contract(w3, vault_address)
            try:
                vault_symbol = vault.functions.symbol().call()
            except Exception:
                vault_symbol = ""
            try:
                vault_name = vault.functions.name().call()
            except Exception:
                vault_name = vault_symbol
            maturities.append(
                {
                    "timestamp": maturity_ts,
                    "label": _maturity_label(maturity_ts),
                    "vault": vault_address.lower(),
                    "symbol": vault_symbol,
                    "name": vault_name,
                }
            )

        return {
            "app": app_address.lower(),
            "chain": chain.lower(),
            "debt_token": debt_token,
            "collaterals": collaterals,
            "maturities": maturities,
        }

    def read_portfolio(
        self,
        app_address: str,
        chain: str,
        user_address: str,
        *,
        app_config: AppConfig | None = None,
        include_wallet: bool = True,
    ) -> dict[str, Any]:
        w3 = make_web3(chain)
        if not w3.is_connected():
            raise ConnectionError(f"RPC unavailable for chain {chain}")

        user = Web3.to_checksum_address(user_address)
        contract = load_contract(w3, app_address)
        market = self.read_market(
            app_address, chain, app_config=app_config
        )

        total_debt = int(contract.functions.totalDebt(user).call())
        collateral_value = int(contract.functions.collateralValue(user).call())
        health_wad = int(contract.functions.healthFactor(user).call())
        current_ltv = int(contract.functions.currentLtv(user).call())
        max_borrow_ltv = int(
            contract.functions.portfolioWeightedMaxBorrowLtv(user).call()
        )
        liquidation_ltv = int(
            contract.functions.portfolioWeightedLiquidationLtv(user).call()
        )

        collateral: list[dict[str, Any]] = []
        for item in market["collaterals"]:
            collateral_id = item["id"]
            amount = int(
                contract.functions.depositedCollateral(user, collateral_id).call()
            )
            if amount == 0:
                continue
            collateral.append(
                {
                    "id": collateral_id,
                    "token": {
                        "address": item["address"],
                        "symbol": item["symbol"],
                        "decimals": item["decimals"],
                    },
                    "amount": str(amount),
                    "max_borrow_ltv_bps": item["max_borrow_ltv_bps"],
                    "liquidation_ltv_bps": item["liquidation_ltv_bps"],
                }
            )

        debts: list[dict[str, Any]] = []
        lending: list[dict[str, Any]] = []
        for maturity in market["maturities"]:
            vault_address = maturity["vault"]
            vault_checksum = Web3.to_checksum_address(vault_address)
            vault = _vault_contract(w3, vault_checksum)
            debt_amount = int(
                contract.functions.debtByVault(user, vault_checksum).call()
            )
            if debt_amount > 0:
                written_down = int(
                    contract.functions.writtenDownByVault(user, vault_checksum).call()
                )
                debts.append(
                    {
                        "maturity": maturity["timestamp"],
                        "label": maturity["label"],
                        "vault": vault_address,
                        "face_debt": str(debt_amount),
                        "written_down": str(written_down),
                    }
                )

            shares = int(vault.functions.balanceOf(user).call())
            if shares > 0:
                assets = int(vault.functions.convertToAssets(shares).call())
                redeemable = int(vault.functions.maxRedeem(user).call())
                redeemable_assets = (
                    int(vault.functions.convertToAssets(redeemable).call())
                    if redeemable > 0
                    else 0
                )
                lending.append(
                    {
                        "maturity": maturity["timestamp"],
                        "label": maturity["label"],
                        "vault": vault_address,
                        "symbol": maturity["symbol"],
                        "shares": str(shares),
                        "assets": str(assets),
                        "redeemable_shares": str(redeemable),
                        "redeemable_assets": str(redeemable_assets),
                    }
                )

        wallet: list[dict[str, Any]] = []
        if include_wallet:
            debt_token = market["debt_token"]
            balance = int(
                _erc20_contract(w3, debt_token["address"])
                .functions.balanceOf(user)
                .call()
            )
            if balance > 0:
                wallet.append(
                    {
                        "token": debt_token,
                        "amount": str(balance),
                    }
                )
            for item in market["collaterals"]:
                balance = int(
                    _erc20_contract(w3, item["address"])
                    .functions.balanceOf(user)
                    .call()
                )
                if balance > 0:
                    wallet.append(
                        {
                            "token": {
                                "address": item["address"],
                                "symbol": item["symbol"],
                                "decimals": item["decimals"],
                            },
                            "amount": str(balance),
                        }
                    )

        wallet_prices = {
            "USDT": SETTINGS.usdt_usd_cents,
            "USDC": SETTINGS.usdc_usd_cents,
            "WETH": SETTINGS.weth_usd_cents,
            "WBTC": SETTINGS.wbtc_usd_cents,
        }
        wallet_value_usd = sum(
            int(item["amount"]) * wallet_prices.get(item["token"]["symbol"], 0)
            // (10 ** int(item["token"]["decimals"]))
            for item in wallet
        )

        health_display = _health_factor_display(health_wad, total_debt)
        if total_debt == 0:
            health_status = "no_debt"
            health_message = "No active debt."
        elif health_wad >= _WAD:
            health_status = "healthy"
            health_message = "Your position is currently healthy."
        else:
            health_status = "unhealthy"
            health_message = "Your position requires attention."

        return {
            "address": user_address.lower(),
            "app": app_address.lower(),
            "chain": chain.lower(),
            "debt_token": market["debt_token"],
            "risk": {
                "total_debt": str(total_debt),
                "collateral_value": str(collateral_value),
                "health_factor_wad": str(health_wad),
                "health_factor": health_display,
                "health_status": health_status,
                "health_message": health_message,
                "risk_percent": current_ltv / 100,
                "current_ltv_bps": current_ltv,
                "max_borrow_ltv_bps": max_borrow_ltv,
                "liquidation_ltv_bps": liquidation_ltv,
            },
            "collateral": collateral,
            "debts": debts,
            "lending": lending,
            "wallet": wallet,
            "wallet_value_usd_cents": str(wallet_value_usd),
        }
