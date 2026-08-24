from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

from .rules import Observation

ALLOWED_EVENT_TYPES = {
    "account_debit",
    "account_credit",
    "card_purchase",
    "card_refund",
    "wallet_charge",
    "wallet_purchase",
    "wallet_refund",
    "financial_notification",
}
ALLOWED_DIRECTIONS = {"debit", "credit", "neutral", "unknown"}
KNOWN_PROVIDER_PACKAGES = {
    "com.kakaobank.channel": "kakaobank",
    "com.kbankwith.smartbank": "kbank",
    "com.wooribank.smart.npib": "wooribank",
    "com.coupang.mobile": "coupang",
}
FORBIDDEN_EVENT_KEYS = {
    "raw_text",
    "raw_title",
    "notification_text",
    "notification_title",
    "account_number",
    "card_number",
    "phone_number",
}


def _require_string(obj: dict[str, Any], key: str, *, max_length: int = 200) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string")
    value = value.strip()
    if len(value) > max_length:
        raise ValueError(f"{key} exceeds maximum length")
    return value


def _parse_event_time(value: str) -> int:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        raise ValueError("occurred_at must include a timezone")
    return int(parsed.astimezone(timezone.utc).timestamp() * 1000)


def _parse_amount(value: Any) -> Decimal | None:
    if value is None:
        return None
    try:
        amount = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError("amount must be decimal-compatible") from exc
    if amount < 0:
        raise ValueError("amount must be an unsigned magnitude; direction is separate")
    return amount


def _hash_device_id(device_id: str) -> str:
    return hashlib.sha256(device_id.encode("utf-8")).hexdigest()


def _optional_short_string(raw: dict[str, Any], key: str, *, max_length: int = 120) -> str | None:
    value = raw.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > max_length:
        raise ValueError(f"{key} must be a short normalized string")
    return value.strip()


def _parse_event(raw: Any, *, batch_id: str, device_id: str) -> Observation:
    if not isinstance(raw, dict):
        raise ValueError("each event must be an object")
    forbidden = FORBIDDEN_EVENT_KEYS.intersection(raw)
    if forbidden:
        raise ValueError(f"raw/private notification fields are forbidden: {sorted(forbidden)}")

    event_id = _require_string(raw, "event_id", max_length=128)
    event_type = _require_string(raw, "event_type", max_length=64)
    if event_type not in ALLOWED_EVENT_TYPES:
        raise ValueError(f"unsupported event_type: {event_type}")
    direction = _require_string(raw, "direction", max_length=16)
    if direction not in ALLOWED_DIRECTIONS:
        raise ValueError(f"unsupported direction: {direction}")

    source_app = _require_string(raw, "source_app", max_length=200)
    provider_key = _require_string(raw, "provider_key", max_length=64)
    expected_provider = KNOWN_PROVIDER_PACKAGES.get(source_app)
    if expected_provider is None or provider_key != expected_provider:
        raise ValueError("source_app/provider_key is not an approved finance provider pair")

    currency = str(raw.get("currency", "KRW")).strip().upper()
    if len(currency) != 3 or not currency.isalpha():
        raise ValueError("currency must be a three-letter code")

    merchant_key = _optional_short_string(raw, "merchant_key")
    account_alias = _optional_short_string(raw, "account_alias")
    balance_after = _parse_amount(raw.get("balance_after"))

    confidence = raw.get("confidence")
    if confidence is not None:
        confidence = float(confidence)
        if confidence < 0 or confidence > 1:
            raise ValueError("confidence must be between 0 and 1")

    occurred_at_ms = _parse_event_time(_require_string(raw, "occurred_at", max_length=64))
    amount = _parse_amount(raw.get("amount"))
    event_hash = hashlib.sha256(
        f"android-notification:{device_id}:{event_id}".encode("utf-8")
    ).hexdigest()

    payload: dict[str, Any] = {
        "source_kind": "android_notification",
        "batch_id": batch_id,
        "device_id_hash": _hash_device_id(device_id),
        "source_app": source_app,
        "provider_key": provider_key,
        "direction": direction,
    }
    if merchant_key is not None:
        payload["merchant_key"] = merchant_key
    if account_alias is not None:
        payload["account_alias"] = account_alias
    if balance_after is not None:
        payload["balance_after"] = str(balance_after)
    if confidence is not None:
        payload["confidence"] = confidence

    return Observation(
        external_event_hash=event_hash,
        event_at_ms=occurred_at_ms,
        observation_type=event_type,
        authority_level="supplemental",
        subject_key=provider_key,
        amount=amount,
        currency=currency,
        normalized_payload=payload,
    )


def parse_notification_batch(payload: bytes) -> tuple[Observation, ...]:
    if len(payload) > 512 * 1024:
        raise ValueError("notification batch exceeds 512 KiB")
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("notification batch must be UTF-8 JSON") from exc
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ValueError("notification batch schema_version must be 1")

    batch_id = _require_string(document, "batch_id", max_length=128)
    device_id = _require_string(document, "device_id", max_length=128)
    events = document.get("events")
    if not isinstance(events, list) or not events:
        raise ValueError("events must contain at least one event")
    if len(events) > 500:
        raise ValueError("notification batch cannot exceed 500 events")
    return tuple(_parse_event(item, batch_id=batch_id, device_id=device_id) for item in events)
