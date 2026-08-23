BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_collector') THEN
    CREATE ROLE finance_collector NOLOGIN;
  END IF;
END
$$;

CREATE TABLE ingest.collection_sources (
  collection_source_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  source_key TEXT NOT NULL,
  source_type TEXT NOT NULL,
  display_label TEXT NOT NULL,
  authority_level TEXT NOT NULL DEFAULT 'supplemental'
    CHECK (authority_level IN ('authoritative', 'reconciling', 'supplemental')),
  enabled BOOLEAN NOT NULL DEFAULT true,
  cadence_seconds INTEGER NOT NULL DEFAULT 3600 CHECK (cadence_seconds BETWEEN 60 AND 2678400),
  freshness_sla_seconds INTEGER NOT NULL DEFAULT 86400 CHECK (freshness_sla_seconds BETWEEN 300 AND 7776000),
  cursor JSONB NOT NULL DEFAULT '{}'::jsonb,
  last_attempt_at TIMESTAMPTZ,
  last_success_at TIMESTAMPTZ,
  last_error_type TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, source_key)
);

CREATE TABLE ingest.collection_runs (
  collection_run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  collection_source_id BIGINT NOT NULL REFERENCES ingest.collection_sources(collection_source_id) ON DELETE CASCADE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'started'
    CHECK (status IN ('started', 'completed', 'partial', 'failed', 'skipped')),
  cursor_before JSONB NOT NULL DEFAULT '{}'::jsonb,
  cursor_after JSONB NOT NULL DEFAULT '{}'::jsonb,
  records_seen INTEGER NOT NULL DEFAULT 0 CHECK (records_seen >= 0),
  records_imported INTEGER NOT NULL DEFAULT 0 CHECK (records_imported >= 0),
  records_ignored INTEGER NOT NULL DEFAULT 0 CHECK (records_ignored >= 0),
  error_count INTEGER NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  error_type TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_collection_runs_source_started
  ON ingest.collection_runs(collection_source_id, started_at DESC);

CREATE TABLE ingest.collection_observations (
  collection_observation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  collection_source_id BIGINT NOT NULL REFERENCES ingest.collection_sources(collection_source_id) ON DELETE CASCADE,
  collection_run_id BIGINT REFERENCES ingest.collection_runs(collection_run_id) ON DELETE SET NULL,
  observed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_at TIMESTAMPTZ,
  observation_type TEXT NOT NULL,
  authority_level TEXT NOT NULL
    CHECK (authority_level IN ('authoritative', 'reconciling', 'supplemental')),
  external_event_hash CHAR(64) NOT NULL,
  subject_key TEXT,
  amount NUMERIC(20,2),
  currency CHAR(3),
  normalized_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  promotion_status TEXT NOT NULL DEFAULT 'staged'
    CHECK (promotion_status IN ('staged', 'promoted', 'ignored', 'needs_review')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (collection_source_id, external_event_hash),
  CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$')
);

CREATE INDEX ix_collection_observations_source_event
  ON ingest.collection_observations(collection_source_id, event_at DESC NULLS LAST, observed_at DESC);
CREATE INDEX ix_collection_observations_type_event
  ON ingest.collection_observations(observation_type, event_at DESC NULLS LAST, observed_at DESC);

CREATE OR REPLACE VIEW analytics.v_collection_source_freshness AS
SELECT
  s.collection_source_id,
  s.household_id,
  h.label AS household_label,
  s.source_key,
  s.source_type,
  s.display_label,
  s.authority_level,
  s.enabled,
  s.cadence_seconds,
  s.freshness_sla_seconds,
  s.last_attempt_at,
  s.last_success_at,
  CASE
    WHEN s.last_success_at IS NULL THEN NULL
    ELSE GREATEST(0, EXTRACT(EPOCH FROM (now() - s.last_success_at))::BIGINT)
  END AS age_seconds,
  CASE
    WHEN NOT s.enabled THEN 'disabled'
    WHEN s.last_success_at IS NULL THEN 'never_collected'
    WHEN now() - s.last_success_at > make_interval(secs => s.freshness_sla_seconds) THEN 'stale'
    ELSE 'fresh'
  END AS freshness_status,
  s.last_error_type
FROM ingest.collection_sources s
JOIN finance.households h USING (household_id);

CREATE OR REPLACE VIEW analytics.v_collection_observation_summary AS
SELECT
  s.household_id,
  h.label AS household_label,
  date_trunc('day', COALESCE(o.event_at, o.observed_at))::date AS observation_day,
  o.observation_type,
  o.authority_level,
  o.currency,
  COUNT(*)::BIGINT AS observation_count,
  SUM(o.amount)::NUMERIC(20,2) AS observed_amount,
  COUNT(*) FILTER (WHERE o.promotion_status = 'promoted')::BIGINT AS promoted_count,
  COUNT(*) FILTER (WHERE o.promotion_status = 'needs_review')::BIGINT AS needs_review_count
FROM ingest.collection_observations o
JOIN ingest.collection_sources s USING (collection_source_id)
JOIN finance.households h USING (household_id)
GROUP BY s.household_id, h.label,
         date_trunc('day', COALESCE(o.event_at, o.observed_at))::date,
         o.observation_type, o.authority_level, o.currency;

CREATE OR REPLACE VIEW analytics.v_household_change_summary_by_currency AS
WITH net_worth_ranked AS (
  SELECT
    n.household_id,
    n.currency,
    n.month,
    n.net_worth,
    n.net_worth_change,
    ROW_NUMBER() OVER (PARTITION BY n.household_id, n.currency ORDER BY n.month DESC) AS rn
  FROM analytics.v_net_worth_history_by_currency n
),
cash_flow_ranked AS (
  SELECT
    c.household_id,
    c.currency,
    c.month,
    c.net_cash_flow,
    LEAD(c.net_cash_flow) OVER (
      PARTITION BY c.household_id, c.currency ORDER BY c.month DESC
    ) AS previous_month_net_cash_flow,
    ROW_NUMBER() OVER (PARTITION BY c.household_id, c.currency ORDER BY c.month DESC) AS rn
  FROM analytics.v_monthly_cash_flow_calendar c
),
latest_net_worth AS (
  SELECT * FROM net_worth_ranked WHERE rn = 1
),
latest_cash_flow AS (
  SELECT * FROM cash_flow_ranked WHERE rn = 1
),
keys AS (
  SELECT household_id, currency FROM latest_net_worth
  UNION
  SELECT household_id, currency FROM latest_cash_flow
)
SELECT
  k.household_id,
  k.currency,
  n.month AS latest_net_worth_month,
  n.net_worth,
  n.net_worth_change,
  c.month AS latest_cash_flow_month,
  c.net_cash_flow,
  c.previous_month_net_cash_flow,
  CASE
    WHEN c.net_cash_flow IS NULL OR c.previous_month_net_cash_flow IS NULL THEN NULL
    ELSE (c.net_cash_flow - c.previous_month_net_cash_flow)::NUMERIC(20,2)
  END AS net_cash_flow_change
FROM keys k
LEFT JOIN latest_net_worth n USING (household_id, currency)
LEFT JOIN latest_cash_flow c USING (household_id, currency);

GRANT USAGE ON SCHEMA ingest TO finance_collector;
GRANT SELECT, INSERT, UPDATE ON ingest.collection_sources TO finance_collector;
GRANT SELECT, INSERT, UPDATE ON ingest.collection_runs TO finance_collector;
GRANT SELECT, INSERT, UPDATE ON ingest.collection_observations TO finance_collector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ingest TO finance_collector;

GRANT SELECT, INSERT, UPDATE ON ingest.collection_sources TO finance_app;
GRANT SELECT, INSERT, UPDATE ON ingest.collection_runs TO finance_app;
GRANT SELECT, INSERT, UPDATE ON ingest.collection_observations TO finance_app;

GRANT SELECT ON analytics.v_collection_source_freshness TO finance_ai_reader;
GRANT SELECT ON analytics.v_collection_observation_summary TO finance_ai_reader;
GRANT SELECT ON analytics.v_household_change_summary_by_currency TO finance_ai_reader;

GRANT SELECT ON analytics.v_collection_source_freshness TO finance_mcp_reader;
GRANT SELECT ON analytics.v_collection_observation_summary TO finance_mcp_reader;
GRANT SELECT ON analytics.v_household_change_summary_by_currency TO finance_mcp_reader;

COMMIT;
