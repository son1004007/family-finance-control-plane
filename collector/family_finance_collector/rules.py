from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from email.utils import parseaddr
from typing import Any

from .config import MailRule


@dataclass(frozen=True)
class MailEnvelope:
    message_id: str
    internal_date_ms: int
    sender: str
    subject: str
    snippet: str


@dataclass(frozen=True)
class Observation:
    external_event_hash: str
    event_at_ms: int
    observation_type: str
    authority_level: str
    subject_key: str
    amount: Decimal | None
    currency: str | None
    normalized_payload: dict[str, Any]


def _matches(pattern: str | None, value: str) -> bool:
    return pattern is None or re.search(pattern, value) is not None


def _sender_domain(sender: str) -> str | None:
    address = parseaddr(sender)[1].strip().lower()
    if "@" not in address:
        return None
    return address.rsplit("@", 1)[1]


def _extract_amount(pattern: str | None, text: str) -> Decimal | None:
    if not pattern:
        return None
    match = re.search(pattern, text)
    if not match:
        return None
    raw = match.groupdict().get("amount") if match.groupdict() else None
    if raw is None:
        raw = match.group(1) if match.lastindex else match.group(0)
    normalized = re.sub(r"[^0-9.\-]", "", raw)
    if not normalized or normalized in {"-", ".", "-."}:
        return None
    try:
        return Decimal(normalized)
    except InvalidOperation:
        return None


def classify(envelope: MailEnvelope, rules: tuple[MailRule, ...]) -> list[Observation]:
    """Classify one message without returning/storing its raw subject or snippet."""
    observations: list[Observation] = []
    searchable = f"{envelope.subject}\n{envelope.snippet}"
    for rule in rules:
        if not _matches(rule.from_regex, envelope.sender):
            continue
        if not _matches(rule.subject_regex, envelope.subject):
            continue
        if not _matches(rule.snippet_regex, envelope.snippet):
            continue

        event_hash = hashlib.sha256(
            f"gmail:{envelope.message_id}:{rule.rule_id}".encode("utf-8")
        ).hexdigest()
        observations.append(
            Observation(
                external_event_hash=event_hash,
                event_at_ms=envelope.internal_date_ms,
                observation_type=rule.observation_type,
                authority_level=rule.authority_level,
                subject_key=rule.rule_id,
                amount=_extract_amount(rule.amount_regex, searchable),
                currency=rule.currency,
                normalized_payload={
                    "rule_id": rule.rule_id,
                    "sender_domain": _sender_domain(envelope.sender),
                    "source_kind": "gmail_metadata",
                },
            )
        )
    return observations
