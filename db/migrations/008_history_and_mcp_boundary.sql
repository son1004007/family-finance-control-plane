BEGIN;

-- A stricter group role for remote/adapter-facing access. Unlike the broader
-- local AI reader, this role is intentionally limited to curated analytics
-- views and receives no direct SELECT on raw finance/planning tables.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_mcp_reader') THEN
    CREATE ROLE finance_mcp_reader NOLOGIN;
  END IF;
END
$$;

REVOKE ALL ON SCHEMA ingest, finance, planning, analytics FROM finance_mcp_reader;
GRANT USAGE ON SCHEMA analytics TO finance_mcp_reader;

CREATE OR REPLACE VIEW analytics.v_household_directory AS
SELECT
  household_id,
  label AS household_label,
  base_currency
FROM finance.households;

CREATE OR REPLACE VIEW analytics.v_net_worth_history_by_currency AS
WITH snapshot_months AS (
  SELECT a.household_id, s.currency, date_trunc('month', s.balance_at)::date AS month
  FROM finance.account_balance_snapshots s
  JOIN finance.accounts a USING (account_id)
  UNION
  SELECT household_id, currency, date_trunc('month', valued_at)::date
  FROM finance.asset_snapshots
  UNION
  SELECT household_id, currency, date_trunc('month', valued_at)::date
  FROM finance.liability_snapshots
),
bounds AS (
  SELECT household_id, currency, MIN(month) AS first_month, MAX(month) AS last_month
  FROM snapshot_months
  GROUP BY household_id, currency
),
calendar AS (
  SELECT
    b.household_id,
    b.currency,
    gs::date AS month
  FROM bounds b
  CROSS JOIN LATERAL generate_series(
    b.first_month::timestamp,
    b.last_month::timestamp,
    interval '1 month'
  ) AS gs
),
account_entities AS (
  SELECT DISTINCT a.household_id, a.account_id, s.currency
  FROM finance.accounts a
  JOIN finance.account_balance_snapshots s USING (account_id)
),
account_rollup AS (
  SELECT
    c.household_id,
    c.currency,
    c.month,
    COALESCE(SUM(latest.balance), 0)::NUMERIC(20,2) AS account_balances
  FROM calendar c
  LEFT JOIN account_entities e
    ON e.household_id = c.household_id AND e.currency = c.currency
  LEFT JOIN LATERAL (
    SELECT s.balance
    FROM finance.account_balance_snapshots s
    WHERE s.account_id = e.account_id
      AND s.currency = c.currency
      AND s.balance_at < (c.month + interval '1 month')
    ORDER BY s.balance_at DESC, s.account_balance_snapshot_id DESC
    LIMIT 1
  ) latest ON true
  GROUP BY c.household_id, c.currency, c.month
),
asset_entities AS (
  SELECT DISTINCT household_id, asset_label, currency
  FROM finance.asset_snapshots
),
asset_rollup AS (
  SELECT
    c.household_id,
    c.currency,
    c.month,
    COALESCE(SUM(latest.market_value), 0)::NUMERIC(20,2) AS other_assets
  FROM calendar c
  LEFT JOIN asset_entities e
    ON e.household_id = c.household_id AND e.currency = c.currency
  LEFT JOIN LATERAL (
    SELECT s.market_value
    FROM finance.asset_snapshots s
    WHERE s.household_id = e.household_id
      AND s.asset_label = e.asset_label
      AND s.currency = e.currency
      AND s.valued_at < (c.month + interval '1 month')
    ORDER BY s.valued_at DESC, s.asset_snapshot_id DESC
    LIMIT 1
  ) latest ON true
  GROUP BY c.household_id, c.currency, c.month
),
liability_entities AS (
  SELECT DISTINCT household_id, liability_label, currency
  FROM finance.liability_snapshots
),
liability_rollup AS (
  SELECT
    c.household_id,
    c.currency,
    c.month,
    COALESCE(SUM(latest.principal_balance), 0)::NUMERIC(20,2) AS liabilities
  FROM calendar c
  LEFT JOIN liability_entities e
    ON e.household_id = c.household_id AND e.currency = c.currency
  LEFT JOIN LATERAL (
    SELECT s.principal_balance
    FROM finance.liability_snapshots s
    WHERE s.household_id = e.household_id
      AND s.liability_label = e.liability_label
      AND s.currency = e.currency
      AND s.valued_at < (c.month + interval '1 month')
    ORDER BY s.valued_at DESC, s.liability_snapshot_id DESC
    LIMIT 1
  ) latest ON true
  GROUP BY c.household_id, c.currency, c.month
),
monthly AS (
  SELECT
    c.household_id,
    c.currency,
    c.month,
    COALESCE(a.account_balances, 0)::NUMERIC(20,2) AS account_balances,
    COALESCE(o.other_assets, 0)::NUMERIC(20,2) AS other_assets,
    COALESCE(l.liabilities, 0)::NUMERIC(20,2) AS liabilities,
    (
      COALESCE(a.account_balances, 0)
      + COALESCE(o.other_assets, 0)
      - COALESCE(l.liabilities, 0)
    )::NUMERIC(20,2) AS net_worth
  FROM calendar c
  LEFT JOIN account_rollup a USING (household_id, currency, month)
  LEFT JOIN asset_rollup o USING (household_id, currency, month)
  LEFT JOIN liability_rollup l USING (household_id, currency, month)
)
SELECT
  m.*,
  LAG(m.net_worth) OVER (
    PARTITION BY m.household_id, m.currency ORDER BY m.month
  )::NUMERIC(20,2) AS previous_month_net_worth,
  (
    m.net_worth - LAG(m.net_worth) OVER (
      PARTITION BY m.household_id, m.currency ORDER BY m.month
    )
  )::NUMERIC(20,2) AS net_worth_change
FROM monthly m;

CREATE OR REPLACE VIEW analytics.v_emergency_reserve_coverage AS
SELECT
  lr.household_id,
  lr.currency,
  lr.liquid_reserve,
  ro.monthly_fixed_obligations,
  CASE
    WHEN ro.monthly_fixed_obligations IS NULL OR ro.monthly_fixed_obligations <= 0 THEN NULL
    ELSE ROUND(lr.liquid_reserve / ro.monthly_fixed_obligations, 2)
  END::NUMERIC(20,2) AS coverage_months,
  CASE
    WHEN ro.monthly_fixed_obligations IS NULL THEN 'obligation_basis_missing'
    WHEN ro.monthly_fixed_obligations <= 0 THEN 'no_positive_fixed_obligation'
    ELSE 'calculated'
  END AS coverage_status
FROM analytics.v_liquid_reserve_by_currency lr
LEFT JOIN analytics.v_active_recurring_obligations ro
  USING (household_id, currency);

GRANT SELECT ON analytics.v_household_directory TO finance_mcp_reader;
GRANT SELECT ON analytics.v_household_financial_snapshot_by_currency TO finance_mcp_reader;
GRANT SELECT ON analytics.v_monthly_cash_flow_calendar TO finance_mcp_reader;
GRANT SELECT ON analytics.v_monthly_spending_by_category TO finance_mcp_reader;
GRANT SELECT ON analytics.v_current_income_gap_to_benchmark TO finance_mcp_reader;
GRANT SELECT ON analytics.v_net_worth_history_by_currency TO finance_mcp_reader;
GRANT SELECT ON analytics.v_emergency_reserve_coverage TO finance_mcp_reader;
GRANT SELECT ON analytics.v_household_scenario_outcomes TO finance_mcp_reader;

COMMIT;
