BEGIN;

-- Promotion is intentionally a decision layer, not a write-through trigger.
-- The collector remains staging-only. A separate controlled writer may promote
-- rows later, but only when this view says the observation is ready.
CREATE OR REPLACE VIEW analytics.v_collection_promotion_decisions AS
WITH normalized AS (
  SELECT
    o.collection_observation_id,
    o.collection_source_id,
    s.household_id,
    s.source_key,
    s.source_type,
    o.observed_at,
    o.event_at,
    o.observation_type,
    o.authority_level,
    o.external_event_hash,
    o.subject_key,
    o.amount,
    o.currency,
    o.promotion_status,
    o.normalized_payload,
    NULLIF(BTRIM(o.normalized_payload ->> 'source_kind'), '') AS source_kind,
    NULLIF(BTRIM(o.normalized_payload ->> 'provider_key'), '') AS provider_key,
    NULLIF(BTRIM(o.normalized_payload ->> 'merchant_key'), '') AS merchant_key,
    NULLIF(BTRIM(o.normalized_payload ->> 'funding_target'), '') AS funding_target,
    NULLIF(BTRIM(o.normalized_payload ->> 'account_alias'), '') AS account_alias,
    NULLIF(BTRIM(o.normalized_payload ->> 'direction'), '') AS direction,
    NULLIF(BTRIM(o.normalized_payload #>> '{transfer_reconciliation,status}'), '') AS transfer_status,
    CASE
      WHEN jsonb_typeof(o.normalized_payload -> 'confidence') = 'number'
        THEN (o.normalized_payload ->> 'confidence')::NUMERIC
      ELSE NULL
    END AS confidence
  FROM ingest.collection_observations o
  JOIN ingest.collection_sources s USING (collection_source_id)
),
resolved AS (
  SELECT
    n.*,
    a.account_id AS resolved_account_id,
    a.currency AS resolved_account_currency
  FROM normalized n
  LEFT JOIN finance.accounts a
    ON a.household_id = n.household_id
   AND a.account_label = n.account_alias
   AND a.active
),
decided AS (
  SELECT
    r.*,
    CASE
      WHEN r.promotion_status <> 'staged' THEN 'skip_existing'
      WHEN r.transfer_status = 'matched' THEN 'ignore'
      WHEN r.transfer_status = 'ambiguous' THEN 'needs_review'
      WHEN r.event_at IS NULL THEN 'needs_review'
      WHEN r.amount IS NULL OR r.amount <= 0 THEN 'needs_review'
      WHEN r.currency IS NULL THEN 'needs_review'
      WHEN r.source_kind IS DISTINCT FROM 'android_notification' THEN 'needs_review'
      WHEN r.observation_type = 'financial_notification' THEN 'needs_review'
      WHEN r.observation_type = 'wallet_charge' THEN 'needs_review'
      WHEN r.observation_type = 'account_debit' AND r.funding_target IS NOT NULL THEN 'needs_review'
      WHEN r.observation_type IN ('account_debit', 'account_credit') THEN 'needs_review'
      WHEN r.observation_type NOT IN ('card_purchase', 'wallet_purchase', 'card_refund', 'wallet_refund') THEN 'needs_review'
      WHEN r.account_alias IS NULL THEN 'needs_review'
      WHEN r.resolved_account_id IS NULL THEN 'needs_review'
      WHEN r.resolved_account_currency IS DISTINCT FROM r.currency THEN 'needs_review'
      WHEN r.confidence IS NULL THEN 'needs_review'
      WHEN r.confidence < 0.90 THEN 'needs_review'
      WHEN r.observation_type IN ('card_purchase', 'wallet_purchase') AND r.direction IS DISTINCT FROM 'debit' THEN 'needs_review'
      WHEN r.observation_type IN ('card_refund', 'wallet_refund') AND r.direction IS DISTINCT FROM 'credit' THEN 'needs_review'
      ELSE 'ready'
    END AS promotion_decision,
    CASE
      WHEN r.promotion_status <> 'staged' THEN 'already_processed'
      WHEN r.transfer_status = 'matched' THEN 'matched_internal_transfer'
      WHEN r.transfer_status = 'ambiguous' THEN 'ambiguous_internal_transfer'
      WHEN r.event_at IS NULL THEN 'missing_event_time'
      WHEN r.amount IS NULL OR r.amount <= 0 THEN 'missing_positive_amount'
      WHEN r.currency IS NULL THEN 'missing_currency'
      WHEN r.source_kind IS DISTINCT FROM 'android_notification' THEN 'unsupported_source_kind'
      WHEN r.observation_type = 'financial_notification' THEN 'unclassified_notification'
      WHEN r.observation_type = 'wallet_charge' THEN 'unpaired_wallet_charge'
      WHEN r.observation_type = 'account_debit' AND r.funding_target IS NOT NULL THEN 'unpaired_wallet_funding'
      WHEN r.observation_type IN ('account_debit', 'account_credit') THEN 'bank_account_event_requires_review'
      WHEN r.observation_type NOT IN ('card_purchase', 'wallet_purchase', 'card_refund', 'wallet_refund') THEN 'unsupported_event_type'
      WHEN r.account_alias IS NULL THEN 'missing_account_alias'
      WHEN r.resolved_account_id IS NULL THEN 'unknown_account_alias'
      WHEN r.resolved_account_currency IS DISTINCT FROM r.currency THEN 'account_currency_mismatch'
      WHEN r.confidence IS NULL THEN 'missing_confidence'
      WHEN r.confidence < 0.90 THEN 'low_confidence'
      WHEN r.observation_type IN ('card_purchase', 'wallet_purchase') AND r.direction IS DISTINCT FROM 'debit' THEN 'direction_mismatch'
      WHEN r.observation_type IN ('card_refund', 'wallet_refund') AND r.direction IS DISTINCT FROM 'credit' THEN 'direction_mismatch'
      ELSE 'ready_transaction'
    END AS promotion_reason
  FROM resolved r
)
SELECT
  collection_observation_id,
  collection_source_id,
  household_id,
  source_key,
  source_type,
  observed_at,
  event_at,
  observation_type,
  authority_level,
  external_event_hash,
  subject_key,
  amount,
  currency,
  promotion_status,
  source_kind,
  provider_key,
  merchant_key,
  funding_target,
  account_alias,
  direction,
  confidence,
  transfer_status,
  resolved_account_id,
  resolved_account_currency,
  promotion_decision,
  promotion_reason,
  CASE
    WHEN promotion_decision <> 'ready' THEN NULL
    WHEN observation_type IN ('card_purchase', 'wallet_purchase') THEN -amount
    WHEN observation_type IN ('card_refund', 'wallet_refund') THEN amount
    ELSE NULL
  END::NUMERIC(20,2) AS canonical_amount,
  CASE
    WHEN promotion_decision = 'ready' THEN COALESCE(merchant_key, provider_key, subject_key)
    ELSE NULL
  END AS canonical_counterparty,
  CASE
    WHEN promotion_decision = 'ready' THEN external_event_hash
    ELSE NULL
  END AS canonical_source_hash
FROM decided;

COMMENT ON VIEW analytics.v_collection_promotion_decisions IS
  'Fail-closed staging decision layer. ready rows are canonical transaction candidates; this view never mutates finance tables.';

GRANT SELECT ON analytics.v_collection_promotion_decisions TO finance_ai_reader;
REVOKE ALL ON analytics.v_collection_promotion_decisions FROM finance_mcp_reader;

COMMIT;
