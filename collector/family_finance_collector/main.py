from __future__ import annotations

import logging
import os
import time
from pathlib import Path

from .config import SourceConfig, load_config
from .db import CollectionStore, connect
from .gmail import GmailClient
from .rules import classify

LOGGER = logging.getLogger("family_finance_collector")
logging.basicConfig(level=os.getenv("COLLECTOR_LOG_LEVEL", "INFO").upper())


def _required_path(name: str) -> Path:
    raw = os.getenv(name, "").strip()
    if not raw:
        raise RuntimeError(f"required path environment variable missing: {name}")
    path = Path(raw)
    if not path.is_file():
        raise RuntimeError(f"configured file does not exist: {name}")
    return path


def collect_source(store: CollectionStore, source: SourceConfig, gmail_client: GmailClient) -> None:
    state = store.ensure_source(source)
    if not store.is_due(state, source.cadence_seconds):
        LOGGER.info("collector_source_skipped source=%s reason=not_due", source.source_key)
        return

    run_id = store.begin_run(state.collection_source_id, state.cursor)
    try:
        if source.source_type != "gmail" or source.gmail is None:
            raise RuntimeError("unsupported source type")
        batch = gmail_client.collect(source.gmail, state.cursor)
        seen = len(batch.envelopes)
        imported = 0
        ignored = 0
        for envelope in batch.envelopes:
            observations = classify(envelope, source.gmail.rules)
            if not observations:
                ignored += 1
                continue
            inserted_for_message = False
            for observation in observations:
                if store.insert_observation(
                    state.collection_source_id, run_id, observation
                ):
                    imported += 1
                    inserted_for_message = True
            if not inserted_for_message:
                ignored += 1
        cursor_after = {"history_id": batch.history_id}
        store.complete_run(
            state.collection_source_id,
            run_id,
            cursor_after,
            seen=seen,
            imported=imported,
            ignored=ignored,
        )
        LOGGER.info(
            "collector_source_complete source=%s seen=%d imported=%d ignored=%d full_sync=%s",
            source.source_key,
            seen,
            imported,
            ignored,
            batch.full_sync,
        )
    except Exception as exc:
        store.fail_run(state.collection_source_id, run_id, type(exc).__name__)
        LOGGER.error(
            "collector_source_failed source=%s error_type=%s",
            source.source_key,
            type(exc).__name__,
        )
        raise


def run_cycle() -> None:
    config_path = _required_path("COLLECTOR_CONFIG_FILE")
    token_path = _required_path("GMAIL_TOKEN_FILE")
    config = load_config(config_path)
    gmail_client = GmailClient(token_path)
    with connect() as conn:
        store = CollectionStore(conn)
        failures = 0
        for source in config.sources:
            try:
                collect_source(store, source, gmail_client)
            except Exception:
                failures += 1
        if failures:
            raise RuntimeError(f"{failures} collection source(s) failed")


def main() -> None:
    once = os.getenv("COLLECTOR_ONCE", "0") == "1"
    interval = int(os.getenv("COLLECTOR_TICK_SECONDS", "60"))
    if interval < 30 or interval > 3600:
        raise RuntimeError("COLLECTOR_TICK_SECONDS must be between 30 and 3600")
    while True:
        try:
            run_cycle()
        except Exception as exc:
            LOGGER.error("collector_cycle_failed error_type=%s", type(exc).__name__)
            if once:
                raise
        if once:
            return
        time.sleep(interval)


if __name__ == "__main__":
    main()
