from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any


def _quote_rate(num: str, den: str) -> str:
    n = int(num)
    d = int(den)
    if d == 0:
        return "0"
    return f"{n / d:.18f}".rstrip("0").rstrip(".") or "0"


class Database:
    def __init__(self, path: str | Path):
        self.path = str(path)
        self._uri = self.path.startswith("file:")
        self._keeper: sqlite3.Connection | None = None
        if self._uri and "mode=memory" in self.path:
            self._keeper = self._connect()
        self._create_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=5, uri=self._uri)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA foreign_keys=ON")
        if not (self._uri and "mode=memory" in self.path):
            conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def close(self) -> None:
        if self._keeper is not None:
            self._keeper.close()
            self._keeper = None

    def _create_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS apps (
                    address             TEXT NOT NULL,
                    chain               TEXT NOT NULL,
                    from_block          INTEGER NOT NULL,
                    last_synced_block   INTEGER NOT NULL,
                    last_refresh_at     REAL,
                    PRIMARY KEY (address, chain)
                );

                CREATE TABLE IF NOT EXISTS borrow_orders (
                    app_address         TEXT NOT NULL,
                    chain               TEXT NOT NULL,
                    order_id            INTEGER NOT NULL,
                    borrower            TEXT NOT NULL,
                    maturity            INTEGER NOT NULL,
                    deadline            INTEGER NOT NULL,
                    face_amount         TEXT NOT NULL,
                    min_debt_token_out  TEXT NOT NULL,
                    ltv_bps             INTEGER NOT NULL,
                    collateral_id       INTEGER NOT NULL,
                    filled_face         TEXT NOT NULL DEFAULT '0',
                    cancelled           INTEGER NOT NULL DEFAULT 0,
                    created_block       INTEGER,
                    quote_num           TEXT NOT NULL,
                    quote_den           TEXT NOT NULL,
                    PRIMARY KEY (app_address, chain, order_id)
                );

                CREATE TABLE IF NOT EXISTS supply_orders (
                    app_address         TEXT NOT NULL,
                    chain               TEXT NOT NULL,
                    order_id            INTEGER NOT NULL,
                    supplier            TEXT NOT NULL,
                    maturity            INTEGER NOT NULL,
                    deadline            INTEGER NOT NULL,
                    debt_token_in       TEXT NOT NULL,
                    min_term_out        TEXT NOT NULL,
                    filled_debt_token   TEXT NOT NULL DEFAULT '0',
                    cancelled           INTEGER NOT NULL DEFAULT 0,
                    created_block       INTEGER,
                    quote_num           TEXT NOT NULL,
                    quote_den           TEXT NOT NULL,
                    PRIMARY KEY (app_address, chain, order_id)
                );

                CREATE INDEX IF NOT EXISTS idx_borrow_orders_book
                    ON borrow_orders(app_address, chain, maturity, cancelled);
                CREATE INDEX IF NOT EXISTS idx_supply_orders_book
                    ON supply_orders(app_address, chain, maturity, cancelled);

                CREATE TABLE IF NOT EXISTS maturity_sync (
                    app_address     TEXT NOT NULL,
                    chain           TEXT NOT NULL,
                    maturity        INTEGER NOT NULL,
                    last_synced_at  REAL NOT NULL,
                    PRIMARY KEY (app_address, chain, maturity)
                );
                """
            )

    def upsert_app(
        self,
        address: str,
        chain: str,
        from_block: int,
        *,
        last_synced_block: int | None = None,
    ) -> None:
        address = address.lower()
        chain = chain.lower()
        synced = from_block - 1 if last_synced_block is None else last_synced_block
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO apps (address, chain, from_block, last_synced_block)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(address, chain) DO UPDATE SET
                    from_block = MIN(apps.from_block, excluded.from_block)
                """,
                (address, chain, from_block, synced),
            )

    def get_app(self, address: str, chain: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM apps WHERE address = ? AND chain = ?",
                (address.lower(), chain.lower()),
            ).fetchone()
        return dict(row) if row else None

    def list_apps(self) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM apps ORDER BY chain, address"
            ).fetchall()
        return [dict(row) for row in rows]

    def list_maturities(self, app_address: str, chain: str) -> list[int]:
        app_address = app_address.lower()
        chain = chain.lower()
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT maturity FROM (
                    SELECT maturity FROM borrow_orders
                    WHERE app_address = ? AND chain = ?
                    UNION
                    SELECT maturity FROM supply_orders
                    WHERE app_address = ? AND chain = ?
                )
                ORDER BY maturity ASC
                """,
                (app_address, chain, app_address, chain),
            ).fetchall()
        return [int(row["maturity"]) for row in rows]

    def set_last_synced_block(self, address: str, chain: str, block: int) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE apps SET last_synced_block = ? WHERE address = ? AND chain = ?",
                (block, address.lower(), chain.lower()),
            )

    def set_last_refresh_at(self, address: str, chain: str, ts: float) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE apps SET last_refresh_at = ? WHERE address = ? AND chain = ?",
                (ts, address.lower(), chain.lower()),
            )

    def touch_maturity_sync(
        self, app_address: str, chain: str, maturity: int, synced_at: int
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO maturity_sync (app_address, chain, maturity, last_synced_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(app_address, chain, maturity) DO UPDATE SET
                    last_synced_at = MAX(maturity_sync.last_synced_at, excluded.last_synced_at)
                """,
                (app_address.lower(), chain.lower(), int(maturity), int(synced_at)),
            )

    def get_maturity_sync(
        self, app_address: str, chain: str, maturity: int
    ) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM maturity_sync
                WHERE app_address = ? AND chain = ? AND maturity = ?
                """,
                (app_address.lower(), chain.lower(), int(maturity)),
            ).fetchone()
        return dict(row) if row else None

    def maturity_sync_is_fresh(
        self, app_address: str, chain: str, maturity: int, max_age_seconds: int
    ) -> tuple[bool, dict[str, Any] | None]:
        row = self.get_maturity_sync(app_address, chain, maturity)
        if row is None:
            return False, None
        age = time.time() - float(row["last_synced_at"])
        return age <= max_age_seconds, row

    def purge_orders_before_block(
        self, app_address: str, chain: str, block: int
    ) -> None:
        app_address = app_address.lower()
        chain = chain.lower()
        with self._connect() as conn:
            conn.execute(
                """
                DELETE FROM borrow_orders
                WHERE app_address = ? AND chain = ?
                  AND created_block IS NOT NULL AND created_block < ?
                """,
                (app_address, chain, block),
            )
            conn.execute(
                """
                DELETE FROM supply_orders
                WHERE app_address = ? AND chain = ?
                  AND created_block IS NOT NULL AND created_block < ?
                """,
                (app_address, chain, block),
            )

    def upsert_borrow_order(
        self, order: dict[str, Any], *, synced_at: int | None = None
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO borrow_orders (
                    app_address, chain, order_id, borrower, maturity, deadline,
                    face_amount, min_debt_token_out, ltv_bps, collateral_id,
                    filled_face, cancelled, created_block, quote_num, quote_den
                ) VALUES (
                    :app_address, :chain, :order_id, :borrower, :maturity, :deadline,
                    :face_amount, :min_debt_token_out, :ltv_bps, :collateral_id,
                    :filled_face, :cancelled, :created_block, :quote_num, :quote_den
                )
                ON CONFLICT(app_address, chain, order_id) DO UPDATE SET
                    filled_face = excluded.filled_face,
                    cancelled = excluded.cancelled
                """,
                order,
            )
        if synced_at is not None:
            self.touch_maturity_sync(
                order["app_address"], order["chain"], order["maturity"], synced_at
            )

    def upsert_supply_order(
        self, order: dict[str, Any], *, synced_at: int | None = None
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO supply_orders (
                    app_address, chain, order_id, supplier, maturity, deadline,
                    debt_token_in, min_term_out, filled_debt_token, cancelled,
                    created_block, quote_num, quote_den
                ) VALUES (
                    :app_address, :chain, :order_id, :supplier, :maturity, :deadline,
                    :debt_token_in, :min_term_out, :filled_debt_token, :cancelled,
                    :created_block, :quote_num, :quote_den
                )
                ON CONFLICT(app_address, chain, order_id) DO UPDATE SET
                    filled_debt_token = excluded.filled_debt_token,
                    cancelled = excluded.cancelled
                """,
                order,
            )
        if synced_at is not None:
            self.touch_maturity_sync(
                order["app_address"], order["chain"], order["maturity"], synced_at
            )

    def add_borrow_fill(
        self,
        app_address: str,
        chain: str,
        order_id: int,
        face_amount: int,
        *,
        synced_at: int | None = None,
    ) -> None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT maturity, filled_face FROM borrow_orders
                WHERE app_address = ? AND chain = ? AND order_id = ?
                """,
                (app_address.lower(), chain.lower(), order_id),
            ).fetchone()
            if row is None:
                return
            new_filled = int(row["filled_face"]) + face_amount
            conn.execute(
                """
                UPDATE borrow_orders SET filled_face = ?
                WHERE app_address = ? AND chain = ? AND order_id = ?
                """,
                (str(new_filled), app_address.lower(), chain.lower(), order_id),
            )
        if synced_at is not None:
            self.touch_maturity_sync(app_address, chain, int(row["maturity"]), synced_at)

    def add_supply_fill(
        self,
        app_address: str,
        chain: str,
        order_id: int,
        debt_token_amount: int,
        *,
        synced_at: int | None = None,
    ) -> None:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT maturity, filled_debt_token FROM supply_orders
                WHERE app_address = ? AND chain = ? AND order_id = ?
                """,
                (app_address.lower(), chain.lower(), order_id),
            ).fetchone()
            if row is None:
                return
            new_filled = int(row["filled_debt_token"]) + debt_token_amount
            conn.execute(
                """
                UPDATE supply_orders SET filled_debt_token = ?
                WHERE app_address = ? AND chain = ? AND order_id = ?
                """,
                (str(new_filled), app_address.lower(), chain.lower(), order_id),
            )
        if synced_at is not None:
            self.touch_maturity_sync(app_address, chain, int(row["maturity"]), synced_at)

    def open_borrow_order_ids(self, app_address: str, chain: str) -> list[int]:
        now = int(time.time())
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT order_id FROM borrow_orders
                WHERE app_address = ? AND chain = ? AND cancelled = 0
                  AND CAST(face_amount AS INTEGER) > CAST(filled_face AS INTEGER)
                  AND deadline >= ?
                """,
                (app_address.lower(), chain.lower(), now),
            ).fetchall()
        return [int(row["order_id"]) for row in rows]

    def open_supply_order_ids(self, app_address: str, chain: str) -> list[int]:
        now = int(time.time())
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT order_id FROM supply_orders
                WHERE app_address = ? AND chain = ? AND cancelled = 0
                  AND CAST(debt_token_in AS INTEGER) > CAST(filled_debt_token AS INTEGER)
                  AND deadline >= ?
                """,
                (app_address.lower(), chain.lower(), now),
            ).fetchall()
        return [int(row["order_id"]) for row in rows]

    def _active_borrow_filter(self, include_expired: bool) -> str:
        expiry = "" if include_expired else "AND deadline >= ?"
        return f"""
            cancelled = 0
            AND CAST(face_amount AS INTEGER) > CAST(filled_face AS INTEGER)
            {expiry}
        """

    def _active_supply_filter(self, include_expired: bool) -> str:
        expiry = "" if include_expired else "AND deadline >= ?"
        return f"""
            cancelled = 0
            AND CAST(debt_token_in AS INTEGER) > CAST(filled_debt_token AS INTEGER)
            {expiry}
        """

    def list_sell_orders(
        self,
        app_address: str,
        chain: str,
        maturity: int,
        *,
        page: int,
        limit: int,
        include_expired: bool = False,
    ) -> tuple[list[dict[str, Any]], int]:
        app_address = app_address.lower()
        chain = chain.lower()
        offset = (page - 1) * limit
        where = (
            "app_address = ? AND chain = ? AND maturity = ? AND "
            + self._active_borrow_filter(include_expired)
        )
        args: list[Any] = [app_address, chain, maturity]
        if not include_expired:
            args.append(int(time.time()))

        with self._connect() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) AS c FROM borrow_orders WHERE {where}",
                args,
            ).fetchone()["c"]
            rows = conn.execute(
                f"""
                SELECT * FROM borrow_orders
                WHERE {where}
                ORDER BY CAST(quote_num AS REAL) / CAST(quote_den AS REAL) ASC,
                         order_id ASC
                LIMIT ? OFFSET ?
                """,
                [*args, limit, offset],
            ).fetchall()

        return [self._format_borrow_row(dict(row)) for row in rows], int(total)

    def list_buy_orders(
        self,
        app_address: str,
        chain: str,
        maturity: int,
        *,
        page: int,
        limit: int,
        include_expired: bool = False,
    ) -> tuple[list[dict[str, Any]], int]:
        app_address = app_address.lower()
        chain = chain.lower()
        offset = (page - 1) * limit
        where = (
            "app_address = ? AND chain = ? AND maturity = ? AND "
            + self._active_supply_filter(include_expired)
        )
        args: list[Any] = [app_address, chain, maturity]
        if not include_expired:
            args.append(int(time.time()))

        with self._connect() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) AS c FROM supply_orders WHERE {where}",
                args,
            ).fetchone()["c"]
            rows = conn.execute(
                f"""
                SELECT * FROM supply_orders
                WHERE {where}
                ORDER BY CAST(quote_num AS REAL) / CAST(quote_den AS REAL) DESC,
                         order_id ASC
                LIMIT ? OFFSET ?
                """,
                [*args, limit, offset],
            ).fetchall()

        return [self._format_supply_row(dict(row)) for row in rows], int(total)

    def list_maker_borrow_orders(
        self,
        app_address: str,
        chain: str,
        maker: str,
        *,
        page: int,
        limit: int,
        include_expired: bool = False,
        include_closed: bool = False,
    ) -> tuple[list[dict[str, Any]], int]:
        app_address = app_address.lower()
        chain = chain.lower()
        maker = maker.lower()
        offset = (page - 1) * limit
        filters = ["app_address = ?", "chain = ?", "borrower = ?"]
        args: list[Any] = [app_address, chain, maker]
        if not include_closed:
            filters.append("cancelled = 0")
            filters.append("CAST(face_amount AS INTEGER) > CAST(filled_face AS INTEGER)")
        if not include_expired:
            filters.append("deadline >= ?")
            args.append(int(time.time()))
        where = " AND ".join(filters)

        with self._connect() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) AS c FROM borrow_orders WHERE {where}",
                args,
            ).fetchone()["c"]
            rows = conn.execute(
                f"""
                SELECT * FROM borrow_orders
                WHERE {where}
                ORDER BY maturity ASC, order_id DESC
                LIMIT ? OFFSET ?
                """,
                [*args, limit, offset],
            ).fetchall()

        return [self._format_borrow_row(dict(row)) for row in rows], int(total)

    def list_maker_supply_orders(
        self,
        app_address: str,
        chain: str,
        maker: str,
        *,
        page: int,
        limit: int,
        include_expired: bool = False,
        include_closed: bool = False,
    ) -> tuple[list[dict[str, Any]], int]:
        app_address = app_address.lower()
        chain = chain.lower()
        maker = maker.lower()
        offset = (page - 1) * limit
        filters = ["app_address = ?", "chain = ?", "supplier = ?"]
        args: list[Any] = [app_address, chain, maker]
        if not include_closed:
            filters.append("cancelled = 0")
            filters.append(
                "CAST(debt_token_in AS INTEGER) > CAST(filled_debt_token AS INTEGER)"
            )
        if not include_expired:
            filters.append("deadline >= ?")
            args.append(int(time.time()))
        where = " AND ".join(filters)

        with self._connect() as conn:
            total = conn.execute(
                f"SELECT COUNT(*) AS c FROM supply_orders WHERE {where}",
                args,
            ).fetchone()["c"]
            rows = conn.execute(
                f"""
                SELECT * FROM supply_orders
                WHERE {where}
                ORDER BY maturity ASC, order_id DESC
                LIMIT ? OFFSET ?
                """,
                [*args, limit, offset],
            ).fetchall()

        return [self._format_supply_row(dict(row)) for row in rows], int(total)

    @staticmethod
    def _format_borrow_row(row: dict[str, Any]) -> dict[str, Any]:
        remaining = str(int(row["face_amount"]) - int(row["filled_face"]))
        quote_num = row["quote_num"]
        quote_den = row["quote_den"]
        return {
            "order_id": row["order_id"],
            "side": "sell",
            "maker": row["borrower"],
            "maturity": row["maturity"],
            "deadline": row["deadline"],
            "face_amount": row["face_amount"],
            "filled_face": row["filled_face"],
            "remaining_face": remaining,
            "min_debt_token_out": row["min_debt_token_out"],
            "ltv_bps": row["ltv_bps"],
            "collateral_id": row["collateral_id"],
            "cancelled": bool(row["cancelled"]),
            "quote": {"num": quote_num, "den": quote_den},
            "quote_rate": _quote_rate(quote_num, quote_den),
        }

    @staticmethod
    def _format_supply_row(row: dict[str, Any]) -> dict[str, Any]:
        remaining = str(int(row["debt_token_in"]) - int(row["filled_debt_token"]))
        quote_num = row["quote_num"]
        quote_den = row["quote_den"]
        return {
            "order_id": row["order_id"],
            "side": "buy",
            "maker": row["supplier"],
            "maturity": row["maturity"],
            "deadline": row["deadline"],
            "debt_token_in": row["debt_token_in"],
            "filled_debt_token": row["filled_debt_token"],
            "remaining_debt_token": remaining,
            "min_term_out": row["min_term_out"],
            "cancelled": bool(row["cancelled"]),
            "quote": {"num": quote_num, "den": quote_den},
            "quote_rate": _quote_rate(quote_num, quote_den),
        }
