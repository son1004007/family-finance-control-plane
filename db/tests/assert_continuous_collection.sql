DO $$
DECLARE
  household BIGINT;
  source_id BIGINT;
  freshness TEXT;
  collector_can_ledger BOOLEAN;
BEGIN
  SELECT household_id INTO household
  FROM finance.households
  WHERE label = 'synthetic_household';

  INSERT INTO ingest.collection_sources(
    household_id, source_key, source_type, display_label, authority_level,
    cadence_seconds, freshness_sla_seconds, last_attempt_at, last_success_at
  ) VALUES (
    household, 'synthetic_continuous_source', 'gmail', 'Synthetic source',
    'reconciling', 900, 3600, now(), now()
  )
  ON CONFLICT (household_id, source_key) DO UPDATE SET
    last_attempt_at=EXCLUDED.last_attempt_at,
    last_success_at=EXCLUDED.last_success_at
  RETURNING collection_source_id INTO source_id;

  INSERT INTO ingest.collection_observations(
    collection_source_id, observation_type, authority_level,
    external_event_hash, subject_key, amount, currency
  ) VALUES (
    source_id, 'synthetic_notice', 'supplemental', repeat('b',64),
    'synthetic_rule', 12345, 'KRW'
  )
  ON CONFLICT DO NOTHING;

  SELECT freshness_status INTO freshness
  FROM analytics.v_collection_source_freshness
  WHERE collection_source_id = source_id;

  IF freshness IS DISTINCT FROM 'fresh' THEN
    RAISE EXCEPTION 'expected fresh collection source, got %', freshness;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_collection_observation_summary
    WHERE household_label='synthetic_household'
      AND observation_type='synthetic_notice'
      AND observed_amount=12345::numeric
  ) THEN
    RAISE EXCEPTION 'collection observation summary missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM analytics.v_household_change_summary_by_currency
    WHERE household_id=household AND currency='KRW'
  ) THEN
    RAISE EXCEPTION 'household change summary missing';
  END IF;

  SELECT has_table_privilege('finance_collector','finance.transactions','INSERT')
  INTO collector_can_ledger;
  IF collector_can_ledger THEN
    RAISE EXCEPTION 'finance_collector unexpectedly has finance.transactions INSERT';
  END IF;
END
$$;

SELECT 'CONTINUOUS_COLLECTION_ASSERTIONS=PASS';
