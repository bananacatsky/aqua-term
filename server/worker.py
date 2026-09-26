from __future__ import annotations

import logging
import threading
import time

from db import Database
from sync import ChainSyncer

log = logging.getLogger(__name__)


class SyncWorker:
    def __init__(
        self,
        database: Database,
        syncer: ChainSyncer,
        *,
        poll_interval: float = 12.0,
    ):
        self.database = database
        self.syncer = syncer
        self.poll_interval = poll_interval
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    @property
    def is_alive(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def start(self) -> None:
        if self.is_alive:
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self.run,
            daemon=True,
            name="aquaterm-sync-worker",
        )
        self._thread.start()

    def stop(self, timeout: float = 5) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=timeout)

    def run(self) -> None:
        log.info("AquaTerm sync worker started")
        while not self._stop.is_set():
            started = time.time()
            try:
                self.syncer.sync_all()
            except Exception:
                log.exception("Sync cycle failed")
            elapsed = time.time() - started
            self._stop.wait(max(0.0, self.poll_interval - elapsed))
