CREATE OR REPLACE VIEW analytics.v_monthly_cash_flow AS
SELECT
  a.household_id,
  date_trunc('month', t.occurred_at)::date AS month,
  t.currency,
  SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END) AS inflow,
  ABS(SUM(CASE WHEN t.amount < 0 THEN t.amount ELSE 0 END)) AS outflow,
  SUM(t.amount) AS net_cash_flow,
  COUNT(*) AS transaction_count
FROM finance.transactions t
JOIN finance.accounts a ON a.account_id = t.account_id
GROUP BY a.household_id, date_trunc('month', t.occurred_at)::date, t.currency;

CREATE OR REPLACE VIEW analytics.v_latest_account_balances AS
SELECT DISTINCT ON (a.account_id, s.currency)
  a.household_id,
  a.account_id,
  a.account_label,
  a.account_type,
  s.currency,
  s.balance,
  s.balance_at
FROM finance.account_balance_snapshots s
JOIN finance.accounts a ON a.account_id = s.account_id
ORDER BY a.account_id, s.currency, s.balance_at DESC, s.account_balance_snapshot_id DESC;

CREATE OR REPLACE VIEW analytics.v_latest_assets AS
SELECT DISTINCT ON (household_id, asset_label, currency)
  household_id,
  asset_label,
  asset_type,
  currency,
  market_value,
  liquid_value,
  valued_at
FROM finance.asset_snapshots
ORDER BY household_id, asset_label, currency, valued_at DESC, asset_snapshot_id DESC;

CREATE OR REPLACE VIEW analytics.v_latest_liabilities AS
SELECT DISTINCT ON (household_id, liability_label, currency)
  household_id,
  liability_label,
  liability_type,
  currency,
  principal_balance,
  monthly_payment,
  annual_interest_rate,
  valued_at
FROM finance.liability_snapshots
ORDER BY household_id, liability_label, currency, valued_at DESC, liability_snapshot_id DESC;

-- Account balances and non-account assets are separate inputs. Do not also put the
-- same bank account into asset_snapshots or it will be double counted.
CREATE OR REPLACE VIEW analytics.v_net_worth_by_currency AS
WITH balance_totals AS (
  SELECT household_id, currency, SUM(balance) AS account_balances
  FROM analytics.v_latest_account_balances
  GROUP BY household_id, currency
),
asset_totals AS (
  SELECT household_id, currency, SUM(market_value) AS other_assets
  FROM analytics.v_latest_assets
  GROUP BY household_id, currency
),
liability_totals AS (
  SELECT household_id, currency, SUM(principal_balance) AS liabilities
  FROM analytics.v_latest_liabilities
  GROUP BY household_id, currency
),
currencies AS (
  SELECT household_id, currency FROM balance_totals
  UNION
  SELECT household_id, currency FROM asset_totals
  UNION
  SELECT household_id, currency FROM liability_totals
)
SELECT
  c.household_id,
  c.currency,
  COALESCE(b.account_balances, 0)::NUMERIC(20,2) AS account_balances,
  COALESCE(a.other_assets, 0)::NUMERIC(20,2) AS other_assets,
  COALESCE(l.liabilities, 0)::NUMERIC(20,2) AS liabilities,
  (COALESCE(b.account_balances, 0) + COALESCE(a.other_assets, 0) - COALESCE(l.liabilities, 0))::NUMERIC(20,2) AS net_worth
FROM currencies c
LEFT JOIN balance_totals b USING (household_id, currency)
LEFT JOIN asset_totals a USING (household_id, currency)
LEFT JOIN liability_totals l USING (household_id, currency);

CREATE OR REPLACE VIEW analytics.v_active_recurring_obligations AS
SELECT
  household_id,
  currency,
  SUM(monthly_amount)::NUMERIC(20,2) AS monthly_fixed_obligations,
  COUNT(*) AS obligation_count
FROM finance.recurring_obligations
WHERE active
  AND (starts_on IS NULL OR starts_on <= CURRENT_DATE)
  AND (ends_on IS NULL OR ends_on >= CURRENT_DATE)
GROUP BY household_id, currency;
