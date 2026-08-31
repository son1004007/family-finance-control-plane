from __future__ import annotations

import hashlib
from dataclasses import dataclass
from decimal import Decimal
from typing import Iterable

from .rules import Observation

RULE_ID = "bank_debit_wallet_charge_v1"
DEFAULT_WINDOW_MS = 10 * 60 * 1000


@dataclass(frozen=True)
class InternalTransferMatch:
    bank_event_hash: str
    wallet_event_hash: str
    wallet_provider: str
    amount: Decimal
    currency: str
    delta_ms: int
    group_id: str


@dataclass(frozen=True)
class InternalTransferResult:
    matches: tuple[InternalTransferMatch, ...]
    ambiguous_event_hashes: frozenset[str]
    candidate_event_hashes: frozenset[str]


def _payload_string(observation: Observation, key: str) -> str | None:
    value = observation.normalized_payload.get(key)
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    return normalized or None


def _provider_key(observation: Observation) -> str | None:
    return _payload_string(observation, "provider_key") or observation.subject_key.strip() or None


def _is_candidate_pair(
    bank: Observation,
    wallet: Observation,
    *,
    max_delta_ms: int,
) -> bool:
    if bank.observation_type != "account_debit" or wallet.observation_type != "wallet_charge":
        return False
    if bank.amount is None or wallet.amount is None or bank.amount <= 0 or wallet.amount <= 0:
        return False
    if bank.amount != wallet.amount:
        return False
    if bank.currency is None or wallet.currency is None or bank.currency != wallet.currency:
        return False
    if _payload_string(bank, "direction") != "debit":
        return False

    funding_target = _payload_string(bank, "funding_target")
    bank_merchant = _payload_string(bank, "merchant_key")
    wallet_provider = _provider_key(wallet)
    bank_provider = _provider_key(bank)
    if funding_target is None or bank_merchant is None:
        return False
    if wallet_provider is None or bank_provider is None:
        return False
    if bank_provider == wallet_provider:
        return False
    if bank_merchant != funding_target or funding_target != wallet_provider:
        return False

    return abs(bank.event_at_ms - wallet.event_at_ms) <= max_delta_ms


def _group_id(bank_hash: str, wallet_hash: str) -> str:
    return hashlib.sha256(
        f"{RULE_ID}:{bank_hash}:{wallet_hash}".encode("utf-8")
    ).hexdigest()


def reconcile_internal_transfers(
    observations: Iterable[Observation],
    *,
    max_delta_ms: int = DEFAULT_WINDOW_MS,
) -> InternalTransferResult:
    """Find only unambiguous bank-debit -> wallet-charge transfer pairs.

    Matching is intentionally conservative. A pair must have the same positive amount and
    currency, the bank event must carry an explicit normalized `funding_target` equal to the
    wallet provider, the events must fall within the bounded time window, and the candidate
    relation must be one-to-one from both sides. Wallet purchases are deliberately excluded
    so merchant spend remains spend.
    """
    if max_delta_ms <= 0 or max_delta_ms > 60 * 60 * 1000:
        raise ValueError("max_delta_ms must be between 1 ms and 1 hour")

    items = tuple(observations)
    banks = sorted(
        (item for item in items if item.observation_type == "account_debit"),
        key=lambda item: (item.event_at_ms, item.external_event_hash),
    )
    wallets = sorted(
        (item for item in items if item.observation_type == "wallet_charge"),
        key=lambda item: (item.event_at_ms, item.external_event_hash),
    )

    bank_candidates: dict[str, list[Observation]] = {}
    wallet_candidates: dict[str, list[Observation]] = {}
    candidate_pairs: list[tuple[Observation, Observation]] = []
    for bank in banks:
        for wallet in wallets:
            if not _is_candidate_pair(bank, wallet, max_delta_ms=max_delta_ms):
                continue
            bank_candidates.setdefault(bank.external_event_hash, []).append(wallet)
            wallet_candidates.setdefault(wallet.external_event_hash, []).append(bank)
            candidate_pairs.append((bank, wallet))

    matches: list[InternalTransferMatch] = []
    matched_event_hashes: set[str] = set()
    candidate_event_hashes: set[str] = set()
    for bank, wallet in candidate_pairs:
        candidate_event_hashes.update((bank.external_event_hash, wallet.external_event_hash))
        if len(bank_candidates[bank.external_event_hash]) != 1:
            continue
        if len(wallet_candidates[wallet.external_event_hash]) != 1:
            continue
        wallet_provider = _provider_key(wallet)
        assert wallet_provider is not None
        matches.append(
            InternalTransferMatch(
                bank_event_hash=bank.external_event_hash,
                wallet_event_hash=wallet.external_event_hash,
                wallet_provider=wallet_provider,
                amount=bank.amount,
                currency=bank.currency or "",
                delta_ms=abs(bank.event_at_ms - wallet.event_at_ms),
                group_id=_group_id(bank.external_event_hash, wallet.external_event_hash),
            )
        )
        matched_event_hashes.update((bank.external_event_hash, wallet.external_event_hash))

    matches.sort(key=lambda item: (item.bank_event_hash, item.wallet_event_hash))
    ambiguous = candidate_event_hashes - matched_event_hashes
    return InternalTransferResult(
        matches=tuple(matches),
        ambiguous_event_hashes=frozenset(ambiguous),
        candidate_event_hashes=frozenset(candidate_event_hashes),
    )
