from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from .config import SourceConfig
from .reconciliation import RULE_ID, reconcile_internal_transfers
from .rules import Observation


@dataclass(frozen=True)
class SourceState:
    collection_source_id: int
    cursor: dict[str, Any]
    last_attempt_at: datetime | None


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"required environment variable missing: {name}")
    return value


def connect() -> psycopg.Connection[Any]:
    return psycopg.connect(
        host=os.getenv("FINANCE_DB_HOST", "db"),
        port=int(os.getenv("FINANCE_DB_PORT", "5432")),
        dbname=os.getenv("FINANCE_DB_NAME", "family_finance"),
        user=_required("FINANCE_COLLECTOR_DB_USER"),
        password=_required("FINANCE_COLLECTOR_DB_PASSWORD"),
        application_name="family_finance_collector",
        connect_timeout=5,
        options="-c statement_timeout=10000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=5000",
        row_factory=dict_row,
    )


class CollectionStore:
    def __init__(self, conn: psycopg.Connection[Any]) -> None:
        self.conn = conn

    def ensure_source(self, source: SourceConfig) -> SourceState:
        with self.conn.transaction():
            row = self.conn.execute(
                "SELECT household_id FROM finance.households WHERE label = %s",
                (source.household_label,),
            ).fetchone()
            if row is None:
                raise RuntimeError("configured household label does not exist")
            household_id = row["household_id"]
            state = self.conn.execute(
                """
                INSERT INTO ingest.collection_sources(
                    household_id, source_key, source_type, display_label,
                    authority_level, cadence_seconds, freshness_sla_seconds
                )
                VALUES (%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (household_id, source_key) DO UPDATE SET
                    source_type = EXCLUDED.source_type,
                    display_label = EXCLUDED.display_label,
                    authority_level = EXCLUDED.authority_level,
                    cadence_seconds = EXCLUDED.cadence_seconds,
                    freshness_sla_seconds = EXCLUDED.freshness_sla_seconds,
                    updated_at = now()
                RETURNING collection_source_id, cursor, last_attempt_at
                """,
                (
                    household_id,
                    source.source_key,
                    source.source_type,
                    source.display_label,
                    source.authority_level,
                    source.cadence_seconds,
                    source.freshness_sla_seconds,
                ),
            ).fetchone()
            assert state is not None
        return SourceState(
            collection_source_id=state["collection_source_id"],
            cursor=state["cursor"] or {},
            last_attempt_at=state["last_attempt_at"],
        )

    @staticmethod
    def is_due(state: SourceState, cadence_seconds: int) -> bool:
        if state.last_attempt_at is None:
            return True
        now = datetime.now(timezone.utc)
        last = state.last_attempt_at
        if last.tzinfo is None:
            last = last.replace(tzinfo=timezone.utc)
        return (now - last).total_seconds() >= cadence_seconds

    def begin_run(self, source_id: int, cursor: dict[str, Any]) -> int:
        with self.conn.transaction():
            self.conn.execute(
                "UPDATE ingest.collection_sources SET last_attempt_at=now(), updated_at=now() WHERE collection_source_id=%s",
                (source_id,),
            )
            row = self.conn.execute(
                """
                INSERT INTO ingest.collection_runs(collection_source_id, cursor_before)
                VALUES (%s, %s)
                RETURNING collection_run_id
                """,
                (source_id, Jsonb(cursor)),
            ).fetchone()
            assert row is not None
            return row["collection_run_id"]

    def insert_observation(self, source_id: int, run_id: int, observation: Observation) -> bool:
        event_at = datetime.fromtimestamp(observation.event_at_ms / 1000, tz=timezone.utc)
        with self.conn.transaction():
            row = self.conn.execute(
                """
                INSERT INTO ingest.collection_observations(
                    collection_source_id, collection_run_id, event_at,
                    observation_type, authority_level, external_event_hash,
                    subject_key, amount, currency, normalized_payload
                )
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (collection_source_id, external_event_hash) DO NOTHING
                RETURNING collection_observation_id
                """,
                (
                    source_id,
                    run_id,
                    event_at,
                    observation.observation_type,
                    observation.authority_level,
                    observation.external_event_hash,
                    observation.subject_key,
                    observation.amount,
                    observation.currency,
                    Jsonb(observation.normalized_payload),
                ),
            ).fetchone()
            return row is not None

    def reconcile_internal_transfers(self, source_id: int, *, limit: int = 500) -> tuple[int, int]:
        """Annotate only one-to-one bank-debit/wallet-charge matches in staging JSON.

        This never writes canonical finance tables. Ambiguous candidate groups are tagged as
        ambiguous so future promotion logic can fail closed instead of double-counting spend.
        """
        if limit < 2 or limit > 2000:
            raise ValueError("reconciliation limit must be between 2 and 2000")

        with self.conn.transaction():
            rows = self.conn.execute(
                """
                SELECT
                    collection_observation_id,
                    external_event_hash,
                    (EXTRACT(EPOCH FROM event_at) * 1000)::BIGINT AS event_at_ms,
                    observation_type,
                    authority_level,
                    subject_key,
                    amount,
                    currency,
                    normalized_payload
                FROM ingest.collection_observations
                WHERE collection_source_id = %s
                  AND event_at IS NOT NULL
                  AND observation_type IN ('account_debit', 'wallet_charge')
                ORDER BY event_at DESC, collection_observation_id DESC
                LIMIT %s
                """,
                (source_id, limit),
            ).fetchall()

            observations: list[Observation] = []
            ids_by_hash: dict[str, int] = {}
            for row in rows:
                event_hash = str(row["external_event_hash"]).strip()
                payload = row["normalized_payload"]
                if not isinstance(payload, dict):
                    payload = {}
                observations.append(
                    Observation(
                        external_event_hash=event_hash,
                        event_at_ms=int(row["event_at_ms"]),
                        observation_type=str(row["observation_type"]),
                        authority_level=str(row["authority_level"]),
                        subject_key=str(row["subject_key"] or ""),
                        amount=row["amount"],
                        currency=row["currency"],
                        normalized_payload=payload,
                    )
                )
                ids_by_hash[event_hash] = int(row["collection_observation_id"])

            result = reconcile_internal_transfers(observations)
            for match in result.matches:
                common = {
                    "status": "matched",
                    "kind": "internal_transfer",
                    "rule": RULE_ID,
                    "group_id": match.group_id,
                    "wallet_provider": match.wallet_provider,
                    "time_delta_seconds": match.delta_ms // 1000,
                }
                for event_hash, counterpart_hash, role in (
                    (match.bank_event_hash, match.wallet_event_hash, "bank_debit"),
                    (match.wallet_event_hash, match.bank_event_hash, "wallet_charge"),
                ):
                    observation_id = ids_by_hash[event_hash]
                    metadata = dict(common)
                    metadata["role"] = role
                    metadata["counterpart_event_hash"] = counterpart_hash
                    self.conn.execute(
                        """
                        UPDATE ingest.collection_observations
                        SET normalized_payload = normalized_payload || %s
                        WHERE collection_observation_id = %s
                        """,
                        (Jsonb({"transfer_reconciliation": metadata}), observation_id),
                    )

            for event_hash in sorted(result.ambiguous_event_hashes):
                observation_id = ids_by_hash[event_hash]
                self.conn.execute(
                    """
                    UPDATE ingest.collection_observations
                    SET normalized_payload = normalized_payload || %s
                    WHERE collection_observation_id = %s
                    """,
                    (
                        Jsonb(
                            {
                                "transfer_reconciliation": {
                                    "status": "ambiguous",
                                    "kind": "internal_transfer_candidate",
                                    "rule": RULE_ID,
                                }
                            }
                        ),
                        observation_id,
                    ),
                )

        return len(result.matches), len(result.ambiguous_event_hashes)

    def complete_run(
        self,
        source_id: int,
        run_id: int,
        cursor_after: dict[str, Any],
        *,
        seen: int,
        imported: int,
        ignored: int,
    ) -> None:
        with self.conn.transaction():
            self.conn.execute(
                """
                UPDATE ingest.collection_runs
                SET completed_at=now(), status='completed', cursor_after=%s,
                    records_seen=%s, records_imported=%s, records_ignored=%s
                WHERE collection_run_id=%s
                """,
                (Jsonb(cursor_after), seen, imported, ignored, run_id),
            )
            self.conn.execute(
                """
                UPDATE ingest.collection_sources
                SET cursor=%s, last_success_at=now(), last_error_type=NULL, updated_at=now()
                WHERE collection_source_id=%s
                """,
                (Jsonb(cursor_after), source_id),
            )

    def fail_run(self, source_id: int, run_id: int, error_type: str) -> None:
        safe_type = error_type[:120]
        with self.conn.transaction():
            self.conn.execute(
                """
                UPDATE ingest.collection_runs
                SET completed_at=now(), status='failed', error_count=1, error_type=%s
                WHERE collection_run_id=%s
                """,
                (safe_type, run_id),
            )
            self.conn.execute(
                """
                UPDATE ingest.collection_sources
                SET last_error_type=%s, updated_at=now()
                WHERE collection_source_id=%s
                """,
                (safe_type, source_id),
            )
