from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from web3 import Web3
from web3.contract import Contract

from config import EVM_RPC_URLS, SETTINGS, AppConfig
from db import Database

log = logging.getLogger(__name__)

_ABI_PATH = Path(__file__).with_name("abi.json")


def make_web3(chain: str) -> Web3:
    rpc = EVM_RPC_URLS.get(chain.lower())
    if not rpc:
        raise ValueError(f"Unsupported chain {chain!r}")
    return Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": SETTINGS.http_timeout}))


def load_contract(w3: Web3, address: str) -> Contract:
    abi = json.loads(_ABI_PATH.read_text())
    return w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)


class ChainSyncer:
    def __init__(self, database: Database):
        self.database = database

    def ensure_apps(self, apps: tuple[AppConfig, ...]) -> None:
        for app in apps:
            self.database.upsert_app(app.address, app.chain, app.from_block)

    def sync_all(self) -> None:
        for app in self.database.list_apps():
            try:
                self.sync_app(app["address"], app["chain"])
            except Exception:
                log.exception(
                    "Failed syncing app %s on %s", app["address"], app["chain"]
                )

    def sync_app(self, address: str, chain: str) -> None:
        app = self.database.get_app(address, chain)
        if app is None:
            raise ValueError(f"App {address} on {chain} is not registered")

        w3 = make_web3(chain)
        if not w3.is_connected():
            raise ConnectionError(f"RPC unavailable for chain {chain}")

        contract = load_contract(w3, address)
        head = w3.eth.block_number
        from_block = app["last_synced_block"] + 1
        if from_block > head:
            if SETTINGS.refresh_open_orders:
                self.refresh_open_orders(address, chain, contract)
            return

        while from_block <= head:
            to_block = min(from_block + SETTINGS.sync_block_chunk - 1, head)
            self._sync_block_range(
                address, chain, contract, from_block=from_block, to_block=to_block
            )
            self.database.set_last_synced_block(address, chain, to_block)
            from_block = to_block + 1

        if SETTINGS.refresh_open_orders:
            self.refresh_open_orders(address, chain, contract)

    def _sync_block_range(
        self,
        address: str,
        chain: str,
        contract: Contract,
        *,
        from_block: int,
        to_block: int,
    ) -> None:
        checksum = Web3.to_checksum_address(address)
        for event_name, handler in (
            ("BorrowOrderCreated", self._handle_borrow_created),
            ("SupplyOrderCreated", self._handle_supply_created),
            ("OrdersMatched", self._handle_orders_matched),
        ):
            event = getattr(contract.events, event_name)
            logs = event.get_logs(from_block=from_block, to_block=to_block)
            for entry in logs:
                if entry["address"].lower() != checksum.lower():
                    continue
                handler(address, chain, entry, block_number=entry["blockNumber"])

    def _handle_borrow_created(
        self, address: str, chain: str, entry: dict[str, Any], *, block_number: int
    ) -> None:
        args = entry["args"]
        face_amount = int(args["faceAmount"])
        min_out = int(args["minDebtTokenOut"])
        self.database.upsert_borrow_order(
            {
                "app_address": address.lower(),
                "chain": chain.lower(),
                "order_id": int(args["orderId"]),
                "borrower": args["borrower"],
                "maturity": int(args["maturity"]),
                "deadline": int(args["deadline"]),
                "face_amount": str(face_amount),
                "min_debt_token_out": str(min_out),
                "ltv_bps": int(args["ltvBps"]),
                "collateral_id": int(args["collateralId"]),
                "filled_face": "0",
                "cancelled": 0,
                "created_block": block_number,
                "quote_num": str(min_out),
                "quote_den": str(face_amount),
            }
        )

    def _handle_supply_created(
        self, address: str, chain: str, entry: dict[str, Any], *, block_number: int
    ) -> None:
        args = entry["args"]
        debt_in = int(args["debtTokenIn"])
        min_out = int(args["minTermOut"])
        self.database.upsert_supply_order(
            {
                "app_address": address.lower(),
                "chain": chain.lower(),
                "order_id": int(args["orderId"]),
                "supplier": args["supplier"],
                "maturity": int(args["maturity"]),
                "deadline": int(args["deadline"]),
                "debt_token_in": str(debt_in),
                "min_term_out": str(min_out),
                "filled_debt_token": "0",
                "cancelled": 0,
                "created_block": block_number,
                "quote_num": str(min_out),
                "quote_den": str(debt_in),
            }
        )

    def _handle_orders_matched(
        self, address: str, chain: str, entry: dict[str, Any], *, block_number: int
    ) -> None:
        del block_number
        args = entry["args"]
        borrow_id = int(args["borrowOrderId"])
        supply_id = int(args["supplyOrderId"])
        face_amount = int(args["faceAmount"])
        debt_amount = int(args["borrowerDebtTokenOut"]) + int(args["matcherDebtToken"])
        self.database.add_borrow_fill(address, chain, borrow_id, face_amount)
        self.database.add_supply_fill(address, chain, supply_id, debt_amount)

    def refresh_open_orders(self, address: str, chain: str, contract: Contract) -> None:
        for order_id in self.database.open_borrow_order_ids(address, chain):
            row = contract.functions.borrowOrders(order_id).call()
            self.database.upsert_borrow_order(
                self._borrow_row_from_chain(address, chain, order_id, row)
            )
        for order_id in self.database.open_supply_order_ids(address, chain):
            row = contract.functions.supplyOrders(order_id).call()
            self.database.upsert_supply_order(
                self._supply_row_from_chain(address, chain, order_id, row)
            )
        self.database.set_last_refresh_at(address, chain, __import__("time").time())

    @staticmethod
    def _borrow_row_from_chain(
        address: str, chain: str, order_id: int, row: tuple[Any, ...]
    ) -> dict[str, Any]:
        (
            borrower,
            maturity,
            deadline,
            face_amount,
            min_debt_token_out,
            ltv_bps,
            collateral_id,
            filled_face,
            cancelled,
        ) = row
        face_amount = int(face_amount)
        min_out = int(min_debt_token_out)
        return {
            "app_address": address.lower(),
            "chain": chain.lower(),
            "order_id": order_id,
            "borrower": borrower,
            "maturity": int(maturity),
            "deadline": int(deadline),
            "face_amount": str(face_amount),
            "min_debt_token_out": str(min_out),
            "ltv_bps": int(ltv_bps),
            "collateral_id": int(collateral_id),
            "filled_face": str(int(filled_face)),
            "cancelled": 1 if cancelled else 0,
            "created_block": None,
            "quote_num": str(min_out),
            "quote_den": str(face_amount),
        }

    @staticmethod
    def _supply_row_from_chain(
        address: str, chain: str, order_id: int, row: tuple[Any, ...]
    ) -> dict[str, Any]:
        (
            supplier,
            maturity,
            deadline,
            debt_token_in,
            min_term_out,
            filled_debt_token,
            cancelled,
        ) = row
        debt_in = int(debt_token_in)
        min_out = int(min_term_out)
        return {
            "app_address": address.lower(),
            "chain": chain.lower(),
            "order_id": order_id,
            "supplier": supplier,
            "maturity": int(maturity),
            "deadline": int(deadline),
            "debt_token_in": str(debt_in),
            "min_term_out": str(min_out),
            "filled_debt_token": str(int(filled_debt_token)),
            "cancelled": 1 if cancelled else 0,
            "created_block": None,
            "quote_num": str(min_out),
            "quote_den": str(debt_in),
        }
