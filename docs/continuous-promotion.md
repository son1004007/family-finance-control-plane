# Continuous collection promotion boundary

The collector is a staging writer, not a canonical-ledger writer.

`ingest.collection_observations` can contain normalized evidence from Android notifications, Gmail or future provider connectors. Promotion into `finance.transactions` must remain deterministic and fail closed.

## Decision view

Migration `010_collection_promotion_decisions.sql` creates:

- `analytics.v_collection_promotion_decisions`

The view never mutates data. It produces one of four decisions:

- `ready`: a canonical transaction candidate is structurally safe enough for a separate controlled writer to consider.
- `ignore`: the observation is a matched internal-transfer representation and must not be counted as spend/income independently.
- `needs_review`: required evidence is missing, ambiguous or below policy thresholds.
- `skip_existing`: the staging row is no longer in `staged` promotion status.

## Current automatic-ready policy

The initial policy is deliberately narrow. An Android observation is `ready` only when all of these are true:

1. source kind is `android_notification`;
2. promotion status is still `staged`;
3. event time, positive unsigned amount and currency are present;
4. event type is one of `card_purchase`, `wallet_purchase`, `card_refund`, `wallet_refund`;
5. normalized `account_alias` resolves to exactly the active household account label;
6. observation currency matches that account currency;
7. confidence is at least `0.90`;
8. purchase direction is `debit` and refund direction is `credit`;
9. the event is not part of a matched or ambiguous transfer reconciliation.

Debit purchase candidates expose a negative `canonical_amount`; refund candidates expose a positive amount.

## Why bank-account events remain review-only

`account_debit` and `account_credit` are intentionally not auto-promoted yet. A bank-side debit can be a merchant payment, cash withdrawal, account transfer or wallet funding. Without stronger normalized classification, auto-promoting it could double-count household cash flow.

A bank debit with `funding_target` is treated as wallet funding evidence. It becomes `ignore` only after deterministic one-to-one transfer reconciliation marks it `matched`; otherwise it remains `needs_review`.

Unmatched `wallet_charge` is also review-only so wallet top-ups cannot be counted as income or spending.

## Account mapping boundary

`account_alias` is a normalized logical alias, not an account number. The decision layer resolves it only within the source household against an active `finance.accounts.account_label`.

Missing aliases, unknown aliases and currency mismatches all fail closed. Raw bank/card identifiers are never required for promotion.

## Access boundary

- `finance_collector`: cannot read the promotion decision view and cannot write canonical finance tables.
- `finance_mcp_reader`: cannot read staging promotion decisions.
- `finance_ai_reader`: may inspect the decision view read-only for local diagnostics.
- canonical write-through is not implemented by this migration.

A later controlled promotion worker must re-check the decision and account mapping inside the same transaction before inserting a canonical fact and updating `promotion_status`.
