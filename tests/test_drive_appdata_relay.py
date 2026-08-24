from __future__ import annotations

import json
from decimal import Decimal

from collector.family_finance_collector.drive_appdata import parse_notification_batch


def _payload(event: dict[str, object]) -> bytes:
    return json.dumps(
        {
            "schema_version": 1,
            "batch_id": "synthetic-batch-001",
            "device_id": "synthetic-device-a",
            "events": [event],
        }
    ).encode("utf-8")


def test_parses_normalized_debit_without_raw_text() -> None:
    observations = parse_notification_batch(
        _payload(
            {
                "event_id": "event-001",
                "occurred_at": "2026-08-25T07:00:00+09:00",
                "event_type": "account_debit",
                "amount": "12500",
                "currency": "KRW",
                "direction": "debit",
                "source_app": "example.bank.app",
                "merchant_key": "example_wallet",
                "account_alias": "daily_spending",
                "confidence": 0.95,
            }
        )
    )
    assert len(observations) == 1
    item = observations[0]
    assert item.amount == Decimal("12500")
    assert item.currency == "KRW"
    assert item.observation_type == "account_debit"
    assert item.authority_level == "supplemental"
    assert item.normalized_payload["direction"] == "debit"
    assert item.normalized_payload["merchant_key"] == "example_wallet"
    assert "raw_text" not in item.normalized_payload
    assert "device_id" not in item.normalized_payload
    assert len(item.normalized_payload["device_id_hash"]) == 64


def test_rejects_raw_notification_content() -> None:
    try:
        parse_notification_batch(
            _payload(
                {
                    "event_id": "event-002",
                    "occurred_at": "2026-08-25T07:01:00+09:00",
                    "event_type": "financial_notification",
                    "amount": "1000",
                    "currency": "KRW",
                    "direction": "unknown",
                    "source_app": "example.bank.app",
                    "raw_text": "private notification text must not leave the phone",
                }
            )
        )
    except ValueError as exc:
        assert "forbidden" in str(exc)
    else:
        raise AssertionError("raw notification content should be rejected")


def test_rejects_negative_amount_and_uses_direction_separately() -> None:
    try:
        parse_notification_batch(
            _payload(
                {
                    "event_id": "event-003",
                    "occurred_at": "2026-08-25T07:02:00+09:00",
                    "event_type": "account_debit",
                    "amount": "-1000",
                    "currency": "KRW",
                    "direction": "debit",
                    "source_app": "example.bank.app",
                }
            )
        )
    except ValueError as exc:
        assert "unsigned magnitude" in str(exc)
    else:
        raise AssertionError("negative amount should be rejected")


if __name__ == "__main__":
    test_parses_normalized_debit_without_raw_text()
    test_rejects_raw_notification_content()
    test_rejects_negative_amount_and_uses_direction_separately()
    print("DRIVE_APPDATA_RELAY_TESTS=PASS")
