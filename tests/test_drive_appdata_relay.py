from __future__ import annotations

import json
import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "collector"))

from family_finance_collector.device_relay import parse_notification_batch


def _payload(event: dict[str, object]) -> bytes:
    return json.dumps(
        {
            "schema_version": 1,
            "batch_id": "synthetic-batch-001",
            "device_id": "synthetic-device-a",
            "events": [event],
        }
    ).encode("utf-8")


def _bank_event(**overrides: object) -> dict[str, object]:
    event: dict[str, object] = {
        "event_id": "event-001",
        "occurred_at": "2026-08-25T07:00:00+09:00",
        "event_type": "account_debit",
        "amount": "12500",
        "currency": "KRW",
        "direction": "debit",
        "source_app": "com.kakaobank.channel",
        "provider_key": "kakaobank",
        "confidence": 0.95,
    }
    event.update(overrides)
    return event


def test_parses_normalized_debit_without_raw_text() -> None:
    observations = parse_notification_batch(
        _payload(
            _bank_event(
                merchant_key="example_wallet",
                account_alias="daily_spending",
                balance_after="987654",
            )
        )
    )
    assert len(observations) == 1
    item = observations[0]
    assert item.amount == Decimal("12500")
    assert item.currency == "KRW"
    assert item.observation_type == "account_debit"
    assert item.authority_level == "supplemental"
    assert item.subject_key == "kakaobank"
    assert item.normalized_payload["direction"] == "debit"
    assert item.normalized_payload["provider_key"] == "kakaobank"
    assert item.normalized_payload["merchant_key"] == "example_wallet"
    assert item.normalized_payload["balance_after"] == "987654"
    assert "raw_text" not in item.normalized_payload
    assert "device_id" not in item.normalized_payload
    assert len(item.normalized_payload["device_id_hash"]) == 64


def test_rejects_raw_notification_content() -> None:
    try:
        parse_notification_batch(
            _payload(
                _bank_event(
                    event_id="event-002",
                    event_type="financial_notification",
                    direction="unknown",
                    raw_text="private notification text must not leave the phone",
                )
            )
        )
    except ValueError as exc:
        assert "forbidden" in str(exc)
    else:
        raise AssertionError("raw notification content should be rejected")


def test_rejects_negative_amount_and_uses_direction_separately() -> None:
    try:
        parse_notification_batch(_payload(_bank_event(event_id="event-003", amount="-1000")))
    except ValueError as exc:
        assert "unsigned magnitude" in str(exc)
    else:
        raise AssertionError("negative amount should be rejected")


def test_rejects_unapproved_provider_package_pair() -> None:
    try:
        parse_notification_batch(
            _payload(
                _bank_event(
                    event_id="event-004",
                    source_app="com.example.chat",
                    provider_key="kakaobank",
                )
            )
        )
    except ValueError as exc:
        assert "approved finance provider pair" in str(exc)
    else:
        raise AssertionError("unknown notification apps must fail closed")


def test_rejects_provider_spoof_for_known_package() -> None:
    try:
        parse_notification_batch(
            _payload(
                _bank_event(
                    event_id="event-005",
                    source_app="com.kbankwith.smartbank",
                    provider_key="kakaobank",
                )
            )
        )
    except ValueError as exc:
        assert "approved finance provider pair" in str(exc)
    else:
        raise AssertionError("provider/package mismatch must fail closed")


if __name__ == "__main__":
    test_parses_normalized_debit_without_raw_text()
    test_rejects_raw_notification_content()
    test_rejects_negative_amount_and_uses_direction_separately()
    test_rejects_unapproved_provider_package_pair()
    test_rejects_provider_spoof_for_known_package()
    print("DRIVE_APPDATA_RELAY_TESTS=PASS")
