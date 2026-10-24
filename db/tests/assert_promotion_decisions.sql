\set ON_ERROR_STOP on

INSERT INTO ingest.collection_sources(
  household_id,
  source_key,
  source_type,
  display_label,
  authority_level,
  enabled
)
SELECT household_id, 'promotion_ci', 'device_relay', 'Synthetic promotion CI', 'supplemental', true
FROM finance.households
WHERE label = 'synthetic_household'
ON CONFLICT (household_id, source_key) DO NOTHING;

WITH source AS (
  SELECT collection_source_id
  FROM ingest.collection_sources
  WHERE source_key = 'promotion_ci'
), rows(event_at, observation_type, event_hash, amount, currency, promotion_status, payload) AS (
  VALUES
    (
      TIMESTAMPTZ '2026-02-01 10:00:00+09',
      'wallet_purchase',
      repeat('1', 64),
      12345::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_wallet","merchant_key":"synthetic_merchant","account_alias":"synthetic_checking","direction":"debit","confidence":0.92}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:01:00+09',
      'card_refund',
      repeat('2', 64),
      5000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_card","merchant_key":"synthetic_merchant","account_alias":"synthetic_checking","direction":"credit","confidence":0.96}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:02:00+09',
      'account_debit',
      repeat('3', 64),
      50000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_bank","merchant_key":"synthetic_wallet","funding_target":"synthetic_wallet","direction":"debit","confidence":0.96,"transfer_reconciliation":{"status":"matched","rule_id":"bank_debit_wallet_charge_v1"}}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:02:20+09',
      'wallet_charge',
      repeat('4', 64),
      50000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_wallet","direction":"credit","confidence":0.92,"transfer_reconciliation":{"status":"matched","rule_id":"bank_debit_wallet_charge_v1"}}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:03:00+09',
      'account_debit',
      repeat('5', 64),
      70000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_bank","merchant_key":"synthetic_wallet","funding_target":"synthetic_wallet","direction":"debit","confidence":0.96,"transfer_reconciliation":{"status":"ambiguous","rule_id":"bank_debit_wallet_charge_v1"}}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:04:00+09',
      'wallet_charge',
      repeat('6', 64),
      30000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_wallet","direction":"credit","confidence":0.92}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:05:00+09',
      'wallet_purchase',
      repeat('7', 64),
      9000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_wallet","merchant_key":"synthetic_merchant","direction":"debit","confidence":0.92}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:06:00+09',
      'card_purchase',
      repeat('8', 64),
      11000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_card","merchant_key":"synthetic_merchant","account_alias":"synthetic_checking","direction":"debit","confidence":0.40}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:07:00+09',
      'card_purchase',
      repeat('9', 64),
      12000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_card","merchant_key":"synthetic_merchant","account_alias":"does_not_exist","direction":"debit","confidence":0.96}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:08:00+09',
      'card_purchase',
      repeat('a', 64),
      13000::numeric,
      'USD',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_card","merchant_key":"synthetic_merchant","account_alias":"synthetic_checking","direction":"debit","confidence":0.96}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:09:00+09',
      'account_debit',
      repeat('b', 64),
      14000::numeric,
      'KRW',
      'staged',
      '{"source_kind":"android_notification","provider_key":"synthetic_bank","account_alias":"synthetic_checking","direction":"debit","confidence":0.96}'::jsonb
    ),
    (
      TIMESTAMPTZ '2026-02-01 10:10:00+09',
      'wallet_purchase',
      repeat('c', 64),
      15000::numeric,
      'KRW',
      'promoted',
      '{"source_kind":"android_notification","provider_key":"synthetic_wallet","merchant_key":"synthetic_merchant","account_alias":"synthetic_checking","direction":"debit","confidence":0.92}'::jsonb
    )
)
INSERT INTO ingest.collection_observations(
  collection_source_id,
  event_at,
  observation_type,
  authority_level,
  external_event_hash,
  subject_key,
  amount,
  currency,
  promotion_status,
  normalized_payload
)
SELECT
  source.collection_source_id,
  rows.event_at,
  rows.observation_type,
  'supplemental',
  rows.event_hash,
  'synthetic_provider',
  rows.amount,
  rows.currency,
  rows.promotion_status,
  rows.payload
FROM source
CROSS JOIN rows
ON CONFLICT (collection_source_id, external_event_hash) DO NOTHING;

DO $$
DECLARE
  ready_count INTEGER;
  ignored_count INTEGER;
  review_count INTEGER;
  skip_count INTEGER;
  debit_amount NUMERIC;
  refund_amount NUMERIC;
  resolved_account BIGINT;
BEGIN
  SELECT COUNT(*) INTO ready_count
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND promotion_decision = 'ready';
  IF ready_count <> 2 THEN
    RAISE EXCEPTION 'expected 2 ready promotion candidates, got %', ready_count;
  END IF;

  SELECT COUNT(*) INTO ignored_count
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND promotion_decision = 'ignore'
    AND promotion_reason = 'matched_internal_transfer';
  IF ignored_count <> 2 THEN
    RAISE EXCEPTION 'expected 2 matched internal-transfer observations to ignore, got %', ignored_count;
  END IF;

  SELECT COUNT(*) INTO review_count
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND promotion_decision = 'needs_review';
  IF review_count <> 7 THEN
    RAISE EXCEPTION 'expected 7 fail-closed review observations, got %', review_count;
  END IF;

  SELECT COUNT(*) INTO skip_count
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND promotion_decision = 'skip_existing'
    AND promotion_reason = 'already_processed';
  IF skip_count <> 1 THEN
    RAISE EXCEPTION 'expected 1 already-processed observation, got %', skip_count;
  END IF;

  SELECT canonical_amount, resolved_account_id
    INTO debit_amount, resolved_account
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND external_event_hash = repeat('1', 64);
  IF debit_amount IS DISTINCT FROM -12345::numeric OR resolved_account IS NULL THEN
    RAISE EXCEPTION 'wallet purchase canonical candidate is wrong: amount %, account %', debit_amount, resolved_account;
  END IF;

  SELECT canonical_amount INTO refund_amount
  FROM analytics.v_collection_promotion_decisions
  WHERE source_key = 'promotion_ci'
    AND external_event_hash = repeat('2', 64);
  IF refund_amount IS DISTINCT FROM 5000::numeric THEN
    RAISE EXCEPTION 'refund canonical candidate is wrong: %', refund_amount;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('5', 64)
      AND promotion_reason = 'ambiguous_internal_transfer'
  ) THEN
    RAISE EXCEPTION 'ambiguous transfer did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('6', 64)
      AND promotion_reason = 'unpaired_wallet_charge'
  ) THEN
    RAISE EXCEPTION 'unpaired wallet charge did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('7', 64)
      AND promotion_reason = 'missing_account_alias'
  ) THEN
    RAISE EXCEPTION 'missing account alias did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('8', 64)
      AND promotion_reason = 'low_confidence'
  ) THEN
    RAISE EXCEPTION 'low confidence did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('9', 64)
      AND promotion_reason = 'unknown_account_alias'
  ) THEN
    RAISE EXCEPTION 'unknown account alias did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('a', 64)
      AND promotion_reason = 'account_currency_mismatch'
  ) THEN
    RAISE EXCEPTION 'currency mismatch did not fail closed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_promotion_decisions
    WHERE source_key = 'promotion_ci'
      AND external_event_hash = repeat('b', 64)
      AND promotion_reason = 'bank_account_event_requires_review'
  ) THEN
    RAISE EXCEPTION 'bank account debit did not require review';
  END IF;
END
$$;

SET ROLE finance_ai_reader;
SELECT COUNT(*) FROM analytics.v_collection_promotion_decisions WHERE source_key = 'promotion_ci';
RESET ROLE;

DO $$
BEGIN
  RAISE NOTICE 'COLLECTION_PROMOTION_DECISIONS=PASS';
END
$$;
