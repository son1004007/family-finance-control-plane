BEGIN;

CREATE TABLE IF NOT EXISTS planning.income_benchmarks (
  income_benchmark_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  benchmark_label TEXT NOT NULL,
  income_basis TEXT NOT NULL CHECK (income_basis IN ('gross', 'net')),
  annual_target_income NUMERIC(20,2) NOT NULL CHECK (annual_target_income >= 0),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  effective_on DATE NOT NULL,
  source_label TEXT,
  notes TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, benchmark_label, currency, effective_on),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE OR REPLACE VIEW analytics.v_monthly_spending_by_category AS
SELECT
  a.household_id,
  date_trunc('month', t.occurred_at)::date AS month,
  t.currency,
  COALESCE(NULLIF(t.category, ''), 'uncategorized') AS category,
  ABS(SUM(t.amount))::NUMERIC(20,2) AS spending,
  COUNT(*) AS transaction_count
FROM finance.transactions t
JOIN finance.accounts a ON a.account_id = t.account_id
WHERE t.amount < 0
GROUP BY
  a.household_id,
  date_trunc('month', t.occurred_at)::date,
  t.currency,
  COALESCE(NULLIF(t.category, ''), 'uncategorized');

CREATE OR REPLACE VIEW analytics.v_liquid_reserve_by_currency AS
WITH account_totals AS (
  SELECT household_id, currency, SUM(balance) AS liquid_accounts
  FROM analytics.v_latest_account_balances
  GROUP BY household_id, currency
),
asset_totals AS (
  SELECT household_id, currency, SUM(COALESCE(liquid_value, 0)) AS liquid_other_assets
  FROM analytics.v_latest_assets
  GROUP BY household_id, currency
),
currencies AS (
  SELECT household_id, currency FROM account_totals
  UNION
  SELECT household_id, currency FROM asset_totals
)
SELECT
  c.household_id,
  c.currency,
  COALESCE(a.liquid_accounts, 0)::NUMERIC(20,2) AS liquid_accounts,
  COALESCE(o.liquid_other_assets, 0)::NUMERIC(20,2) AS liquid_other_assets,
  (COALESCE(a.liquid_accounts, 0) + COALESCE(o.liquid_other_assets, 0))::NUMERIC(20,2) AS liquid_reserve
FROM currencies c
LEFT JOIN account_totals a USING (household_id, currency)
LEFT JOIN asset_totals o USING (household_id, currency);

CREATE OR REPLACE VIEW analytics.v_monthly_cash_flow_calendar AS
WITH monthly AS (
  SELECT
    a.household_id,
    date_trunc('month', t.occurred_at)::date AS month,
    t.currency,
    SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END)::NUMERIC(20,2) AS inflow,
    ABS(SUM(CASE WHEN t.amount < 0 THEN t.amount ELSE 0 END))::NUMERIC(20,2) AS outflow,
    SUM(t.amount)::NUMERIC(20,2) AS net_cash_flow,
    COUNT(*) AS transaction_count
  FROM finance.transactions t
  JOIN finance.accounts a ON a.account_id = t.account_id
  GROUP BY a.household_id, date_trunc('month', t.occurred_at)::date, t.currency
),
bounds AS (
  SELECT household_id, currency, MIN(month) AS first_month, MAX(month) AS last_month
  FROM monthly
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
)
SELECT
  c.household_id,
  c.month,
  c.currency,
  COALESCE(m.inflow, 0)::NUMERIC(20,2) AS inflow,
  COALESCE(m.outflow, 0)::NUMERIC(20,2) AS outflow,
  COALESCE(m.net_cash_flow, 0)::NUMERIC(20,2) AS net_cash_flow,
  COALESCE(m.transaction_count, 0)::BIGINT AS transaction_count
FROM calendar c
LEFT JOIN monthly m USING (household_id, currency, month);

CREATE OR REPLACE VIEW analytics.v_rolling_cash_flow AS
SELECT
  household_id,
  month,
  currency,
  inflow,
  outflow,
  net_cash_flow,
  transaction_count,
  COUNT(*) OVER w12 AS history_months,
  (SUM(net_cash_flow) OVER w3)::NUMERIC(20,2) AS rolling_3m_net_cash_flow,
  (SUM(net_cash_flow) OVER w6)::NUMERIC(20,2) AS rolling_6m_net_cash_flow,
  (SUM(net_cash_flow) OVER w12)::NUMERIC(20,2) AS rolling_12m_net_cash_flow
FROM analytics.v_monthly_cash_flow_calendar
WINDOW
  w3 AS (PARTITION BY household_id, currency ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
  w6 AS (PARTITION BY household_id, currency ORDER BY month ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
  w12 AS (PARTITION BY household_id, currency ORDER BY month ROWS BETWEEN 11 PRECEDING AND CURRENT ROW);

CREATE OR REPLACE VIEW analytics.v_current_income_gap_to_benchmark AS
WITH latest_benchmark AS (
  SELECT DISTINCT ON (household_id, benchmark_label, currency)
    household_id,
    benchmark_label,
    income_basis,
    annual_target_income,
    currency,
    effective_on,
    source_label
  FROM planning.income_benchmarks
  WHERE active
  ORDER BY household_id, benchmark_label, currency, effective_on DESC, income_benchmark_id DESC
)
SELECT
  b.household_id,
  b.benchmark_label,
  b.income_basis,
  b.currency,
  b.annual_target_income,
  CASE
    WHEN b.income_basis = 'gross' THEN COALESCE(i.annual_gross_income, 0)
    ELSE COALESCE(i.monthly_net_income, 0) * 12
  END::NUMERIC(20,2) AS current_annual_income,
  GREATEST(
    b.annual_target_income - CASE
      WHEN b.income_basis = 'gross' THEN COALESCE(i.annual_gross_income, 0)
      ELSE COALESCE(i.monthly_net_income, 0) * 12
    END,
    0
  )::NUMERIC(20,2) AS annual_income_gap,
  b.effective_on,
  b.source_label
FROM latest_benchmark b
LEFT JOIN analytics.v_current_household_income_by_currency i
  ON i.household_id = b.household_id AND i.currency = b.currency;

CREATE OR REPLACE VIEW analytics.v_household_financial_snapshot_by_currency AS
WITH currencies AS (
  SELECT household_id, currency FROM analytics.v_current_household_income_by_currency
  UNION
  SELECT household_id, currency FROM analytics.v_net_worth_by_currency
  UNION
  SELECT household_id, currency FROM analytics.v_liquid_reserve_by_currency
  UNION
  SELECT household_id, currency FROM analytics.v_active_recurring_obligations
)
SELECT
  c.household_id,
  c.currency,
  COALESCE(i.annual_gross_income, 0)::NUMERIC(20,2) AS annual_gross_income,
  COALESCE(i.monthly_net_income, 0)::NUMERIC(20,2) AS monthly_net_income,
  COALESCE(o.monthly_fixed_obligations, 0)::NUMERIC(20,2) AS monthly_fixed_obligations,
  (COALESCE(i.monthly_net_income, 0) - COALESCE(o.monthly_fixed_obligations, 0))::NUMERIC(20,2) AS fixed_cost_headroom,
  COALESCE(n.net_worth, 0)::NUMERIC(20,2) AS net_worth,
  COALESCE(l.liquid_reserve, 0)::NUMERIC(20,2) AS liquid_reserve,
  i.latest_as_of_date AS income_as_of_date
FROM currencies c
LEFT JOIN analytics.v_current_household_income_by_currency i USING (household_id, currency)
LEFT JOIN analytics.v_active_recurring_obligations o USING (household_id, currency)
LEFT JOIN analytics.v_net_worth_by_currency n USING (household_id, currency)
LEFT JOIN analytics.v_liquid_reserve_by_currency l USING (household_id, currency);

COMMIT;
