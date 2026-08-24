from __future__ import annotations

import logging
import os
import time
from pathlib import Path

from .config import SourceConfig, load_config
from .db import CollectionStore, connect
from .drive_appdata import DriveAppDataClient
from .gmail import GmailClient
from .rules import Observation, classify

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


def _insert_observations(
    store: CollectionStore,
    source_id: int,
    run_id: int,
    observations: tuple[Observation, ...] | list[Observation],
) -> tuple[int, int]:
    imported = 0
    ignored = 0
    for observation in observations:
        if store.insert_observation(source_id, run_id, observation):
            imported += 1
        else:
            ignored += 1
    return imported, ignored


def _collect_gmail_source(
    store: CollectionStore,
    source: SourceConfig,
    gmail_client: GmailClient,
) -> None:
    assert source.gmail is not None
    state = store.ensure_source(source)
    if not store.is_due(state, source.cadence_seconds):
        LOGGER.info("collector_source_skipped source=%s reason=not_due", source.source_key)
        return

    run_id = store.begin_run(state.collection_source_id, state.cursor)
    try:
        batch = gmail_client.collect(source.gmail, state.cursor)
        seen = len(batch.envelopes)
        imported = 0
        ignored = 0
        for envelope in batch.envelopes:
            observations = classify(envelope, source.gmail.rules)
            if not observations:
                ignored += 1
                continue
            inserted, duplicates = _insert_observations(
                store,
                state.collection_source_id,
                run_id,
                observations,
            )
            imported += inserted
            ignored += duplicates
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


def _collect_drive_appdata_source(
    store: CollectionStore,
    source: SourceConfig,
    drive_client: DriveAppDataClient,
) -> None:
    assert source.drive_appdata is not None
    state = store.ensure_source(source)
    if not store.is_due(state, source.cadence_seconds):
        LOGGER.info("collector_source_skipped source=%s reason=not_due", source.source_key)
        return

    run_id = store.begin_run(state.collection_source_id, state.cursor)
    try:
        batch = drive_client.collect(source.drive_appdata)
        imported, ignored = _insert_observations(
            store,
            state.collection_source_id,
            run_id,
            batch.observations,
        )
        cursor_after = {
            "last_files_seen": batch.files_seen,
            "last_events_seen": len(batch.observations),
        }
        store.complete_run(
            state.collection_source_id,
            run_id,
            cursor_after,
            seen=len(batch.observations),
            imported=imported,
            ignored=ignored,
        )
        # Acknowledge only after the staging transaction and source success marker are durable.
        # If deletion fails, the next cycle safely deduplicates by external_event_hash.
        drive_client.acknowledge(batch.processed_file_ids)
        LOGGER.info(
            "collector_source_complete source=%s files=%d seen=%d imported=%d ignored=%d",
            source.source_key,
            batch.files_seen,
            len(batch.observations),
            imported,
            ignored,
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
    config = load_config(config_path)

    gmail_client: GmailClient | None = None
    drive_client: DriveAppDataClient | None = None
    if any(source.source_type == "gmail" for source in config.sources):
        gmail_client = GmailClient(_required_path("GMAIL_TOKEN_FILE"))
    if any(source.source_type == "drive_appdata" for source in config.sources):
        drive_client = DriveAppDataClient(_required_path("DRIVE_APPDATA_TOKEN_FILE"))

    with connect() as conn:
        store = CollectionStore(conn)
        failures = 0
        for source in config.sources:
            try:
                if source.source_type == "gmail" and gmail_client is not None:
                    _collect_gmail_source(store, source, gmail_client)
                elif source.source_type == "drive_appdata" and drive_client is not None:
                    _collect_drive_appdata_source(store, source, drive_client)
                else:
                    raise RuntimeError(f"collector client unavailable for {source.source_type}")
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
