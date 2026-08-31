from __future__ import annotations

import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "collector"))

from family_finance_collector.reconciliation import reconcile_internal_transfers
from family_finance_collector.rules import Observation


def _event(
    event_hash: str,
    *,
    event_at_ms: int,
    observation_type: str,
    provider_key: str,
    amount: str = "50000",
    currency: str = "KRW",
    direction: str,
    merchant_key: str | None = None,
    funding_target: str | None = None,
) -> Observation:
    payload: dict[str, object] = {
        "source_kind": "android_notification",
        "provider_key": provider_key,
        "direction": direction,
    }
    if merchant_key is not None:
        payload["merchant_key"] = merchant_key
    if funding_target is not None:
        payload["funding_target"] = funding_target
    return Observation(
        external_event_hash=event_hash,
        event_at_ms=event_at_ms,
        observation_type=observation_type,
        authority_level="supplemental",
        subject_key=provider_key,
        amount=Decimal(amount),
        currency=currency,
        normalized_payload=payload,
    )


def _bank(event_hash: str, *, event_at_ms: int = 1_000_000, amount: str = "50000") -> Observation:
    return _event(
        event_hash,
        event_at_ms=event_at_ms,
        observation_type="account_debit",
        provider_key="example_bank",
        amount=amount,
        direction="debit",
        merchant_key="example_wallet",
        funding_target="example_wallet",
    )


def _wallet_charge(
    event_hash: str,
    *,
    event_at_ms: int = 1_030_000,
    amount: str = "50000",
    direction: str = "credit",
) -> Observation:
    return _event(
        event_hash,
        event_at_ms=event_at_ms,
        observation_type="wallet_charge",
        provider_key="example_wallet",
        amount=amount,
        direction=direction,
        merchant_key="example_wallet",
    )


def test_matches_unique_bank_debit_to_wallet_charge() -> None:
    result = reconcile_internal_transfers(
        [
            _bank("a" * 64),
            _wallet_charge("b" * 64),
        ]
    )
    assert len(result.matches) == 1
    match = result.matches[0]
    assert match.bank_event_hash == "a" * 64
    assert match.wallet_event_hash == "b" * 64
    assert match.wallet_provider == "example_wallet"
    assert match.amount == Decimal("50000")
    assert match.currency == "KRW"
    assert match.delta_ms == 30_000
    assert len(match.group_id) == 64
    assert not result.ambiguous_event_hashes


def test_accepts_legacy_wallet_charge_direction_for_upgrade_compatibility() -> None:
    result = reconcile_internal_transfers(
        [
            _bank("c" * 64),
            _wallet_charge("d" * 64, direction="debit"),
        ]
    )
    assert len(result.matches) == 1


def test_wallet_purchase_is_never_matched_as_internal_transfer() -> None:
    purchase = _event(
        "e" * 64,
        event_at_ms=1_020_000,
        observation_type="wallet_purchase",
        provider_key="example_wallet",
        direction="debit",
        merchant_key="example_merchant",
    )
    result = reconcile_internal_transfers([_bank("f" * 64), purchase])
    assert not result.matches
    assert not result.candidate_event_hashes


def test_merchant_identity_without_funding_hint_does_not_match() -> None:
    ordinary_bank_debit = _event(
        "f" * 64,
        event_at_ms=1_000_000,
        observation_type="account_debit",
        provider_key="example_bank",
        direction="debit",
        merchant_key="example_wallet",
    )
    result = reconcile_internal_transfers(
        [ordinary_bank_debit, _wallet_charge("e" * 64)]
    )
    assert not result.matches
    assert not result.candidate_event_hashes


def test_requires_exact_amount_currency_provider_and_time_window() -> None:
    wrong_amount = _wallet_charge("1" * 64, amount="49000")
    wrong_currency = _event(
        "2" * 64,
        event_at_ms=1_030_000,
        observation_type="wallet_charge",
        provider_key="example_wallet",
        amount="50000",
        currency="USD",
        direction="credit",
        merchant_key="example_wallet",
    )
    late = _wallet_charge("3" * 64, event_at_ms=1_700_001)
    wrong_provider = _event(
        "4" * 64,
        event_at_ms=1_030_000,
        observation_type="wallet_charge",
        provider_key="other_wallet",
        direction="credit",
        merchant_key="other_wallet",
    )
    result = reconcile_internal_transfers(
        [_bank("5" * 64), wrong_amount, wrong_currency, late, wrong_provider],
        max_delta_ms=600_000,
    )
    assert not result.matches
    assert not result.candidate_event_hashes


def test_ambiguous_same_amount_events_fail_closed() -> None:
    bank = _bank("6" * 64)
    wallet_a = _wallet_charge("7" * 64, event_at_ms=1_010_000)
    wallet_b = _wallet_charge("8" * 64, event_at_ms=1_020_000)
    result = reconcile_internal_transfers([bank, wallet_a, wallet_b])
    assert not result.matches
    assert result.ambiguous_event_hashes == frozenset(
        {"6" * 64, "7" * 64, "8" * 64}
    )


def test_group_id_and_result_are_deterministic_across_input_order() -> None:
    bank = _bank("9" * 64)
    wallet = _wallet_charge("0" * 64)
    forward = reconcile_internal_transfers([bank, wallet])
    reverse = reconcile_internal_transfers([wallet, bank])
    assert forward == reverse


def test_rejects_unbounded_match_window() -> None:
    try:
        reconcile_internal_transfers([], max_delta_ms=60 * 60 * 1000 + 1)
    except ValueError as exc:
        assert "1 hour" in str(exc)
    else:
        raise AssertionError("unbounded transfer windows must fail closed")


if __name__ == "__main__":
    test_matches_unique_bank_debit_to_wallet_charge()
    test_accepts_legacy_wallet_charge_direction_for_upgrade_compatibility()
    test_wallet_purchase_is_never_matched_as_internal_transfer()
    test_merchant_identity_without_funding_hint_does_not_match()
    test_requires_exact_amount_currency_provider_and_time_window()
    test_ambiguous_same_amount_events_fail_closed()
    test_group_id_and_result_are_deterministic_across_input_order()
    test_rejects_unbounded_match_window()
    print("TRANSFER_RECONCILIATION_TESTS=PASS")
