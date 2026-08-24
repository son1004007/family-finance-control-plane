from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

AUTHORITY_LEVELS = {"authoritative", "reconciling", "supplemental"}


@dataclass(frozen=True)
class MailRule:
    rule_id: str
    observation_type: str
    authority_level: str
    from_regex: str | None = None
    subject_regex: str | None = None
    snippet_regex: str | None = None
    amount_regex: str | None = None
    currency: str | None = None


@dataclass(frozen=True)
class GmailSettings:
    user_id: str
    initial_query: str
    max_initial_messages: int
    rules: tuple[MailRule, ...]


@dataclass(frozen=True)
class DriveAppDataSettings:
    file_prefix: str
    max_files_per_cycle: int


@dataclass(frozen=True)
class SourceConfig:
    household_label: str
    source_key: str
    source_type: str
    display_label: str
    authority_level: str
    cadence_seconds: int
    freshness_sla_seconds: int
    gmail: GmailSettings | None = None
    drive_appdata: DriveAppDataSettings | None = None


@dataclass(frozen=True)
class CollectorConfig:
    version: int
    sources: tuple[SourceConfig, ...]


def _require_string(obj: dict[str, Any], key: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string")
    return value.strip()


def _optional_regex(obj: dict[str, Any], key: str) -> str | None:
    value = obj.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty regex when provided")
    re.compile(value)
    return value


def _parse_rule(raw: dict[str, Any]) -> MailRule:
    authority = raw.get("authority_level", "supplemental")
    if authority not in AUTHORITY_LEVELS:
        raise ValueError(f"invalid authority_level: {authority}")
    currency = raw.get("currency")
    if currency is not None:
        if not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency):
            raise ValueError("currency must be a three-letter uppercase code")
    rule = MailRule(
        rule_id=_require_string(raw, "rule_id"),
        observation_type=_require_string(raw, "observation_type"),
        authority_level=authority,
        from_regex=_optional_regex(raw, "from_regex"),
        subject_regex=_optional_regex(raw, "subject_regex"),
        snippet_regex=_optional_regex(raw, "snippet_regex"),
        amount_regex=_optional_regex(raw, "amount_regex"),
        currency=currency,
    )
    if not any((rule.from_regex, rule.subject_regex, rule.snippet_regex)):
        raise ValueError(f"mail rule {rule.rule_id} must define a matching regex")
    return rule


def _parse_source(raw: dict[str, Any]) -> SourceConfig:
    authority = raw.get("authority_level", "supplemental")
    if authority not in AUTHORITY_LEVELS:
        raise ValueError(f"invalid authority_level: {authority}")
    source_type = _require_string(raw, "source_type")
    cadence = int(raw.get("cadence_seconds", 900))
    freshness = int(raw.get("freshness_sla_seconds", max(cadence * 4, 3600)))
    if cadence < 60 or cadence > 2_678_400:
        raise ValueError("cadence_seconds must be between 60 and 2678400")
    if freshness < 300 or freshness > 7_776_000:
        raise ValueError("freshness_sla_seconds must be between 300 and 7776000")

    gmail = None
    drive_appdata = None
    if source_type == "gmail":
        settings = raw.get("gmail")
        if not isinstance(settings, dict):
            raise ValueError("gmail source requires a gmail object")
        rules_raw = settings.get("rules")
        if not isinstance(rules_raw, list) or not rules_raw:
            raise ValueError("gmail.rules must contain at least one rule")
        maximum = int(settings.get("max_initial_messages", 500))
        if maximum < 1 or maximum > 5000:
            raise ValueError("max_initial_messages must be between 1 and 5000")
        gmail = GmailSettings(
            user_id=str(settings.get("user_id", "me")),
            initial_query=str(settings.get("initial_query", "newer_than:30d")),
            max_initial_messages=maximum,
            rules=tuple(_parse_rule(item) for item in rules_raw),
        )
    elif source_type == "drive_appdata":
        settings = raw.get("drive_appdata")
        if not isinstance(settings, dict):
            raise ValueError("drive_appdata source requires a drive_appdata object")
        prefix = _require_string(settings, "file_prefix")
        if len(prefix) > 80 or not re.fullmatch(r"[A-Za-z0-9._-]+", prefix):
            raise ValueError("drive_appdata.file_prefix must be a safe short filename prefix")
        maximum = int(settings.get("max_files_per_cycle", 100))
        if maximum < 1 or maximum > 500:
            raise ValueError("max_files_per_cycle must be between 1 and 500")
        drive_appdata = DriveAppDataSettings(
            file_prefix=prefix,
            max_files_per_cycle=maximum,
        )
    else:
        raise ValueError(f"unsupported source_type: {source_type}")

    return SourceConfig(
        household_label=_require_string(raw, "household_label"),
        source_key=_require_string(raw, "source_key"),
        source_type=source_type,
        display_label=_require_string(raw, "display_label"),
        authority_level=authority,
        cadence_seconds=cadence,
        freshness_sla_seconds=freshness,
        gmail=gmail,
        drive_appdata=drive_appdata,
    )


def load_config(path: str | Path) -> CollectorConfig:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if raw.get("version") != 1:
        raise ValueError("collector config version must be 1")
    sources = raw.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("collector config requires at least one source")
    parsed = tuple(_parse_source(item) for item in sources)
    keys = [(item.household_label, item.source_key) for item in parsed]
    if len(keys) != len(set(keys)):
        raise ValueError("source_key must be unique within each household")
    return CollectorConfig(version=1, sources=parsed)
