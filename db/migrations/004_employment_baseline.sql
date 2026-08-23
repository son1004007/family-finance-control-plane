CREATE TABLE finance.employment_snapshots (
  employment_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  person_id BIGINT NOT NULL REFERENCES finance.persons(person_id) ON DELETE CASCADE,
  employment_status TEXT NOT NULL CHECK (employment_status IN (
    'employed',
    'self_employed',
    'career_break',
    'unemployed',
    'leave',
    'other'
  )),
  employer_label TEXT,
  role_label TEXT,
  annual_gross_income NUMERIC(20,2) CHECK (annual_gross_income IS NULL OR annual_gross_income >= 0),
  monthly_net_income NUMERIC(20,2) CHECK (monthly_net_income IS NULL OR monthly_net_income >= 0),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  work_location_label TEXT,
  as_of_date DATE NOT NULL,
  source_label TEXT NOT NULL DEFAULT 'manual',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (person_id, as_of_date),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX ix_employment_snapshots_household_as_of
  ON finance.employment_snapshots(household_id, as_of_date DESC);

CREATE OR REPLACE VIEW analytics.v_current_employment AS
SELECT DISTINCT ON (e.person_id)
  e.household_id,
  e.person_id,
  p.role_label AS person_role_label,
  e.employment_status,
  e.employer_label,
  e.role_label AS employment_role_label,
  e.annual_gross_income,
  e.monthly_net_income,
  e.currency,
  e.work_location_label,
  e.as_of_date,
  e.source_label
FROM finance.employment_snapshots e
JOIN finance.persons p ON p.person_id = e.person_id
WHERE p.active
ORDER BY e.person_id, e.as_of_date DESC, e.employment_snapshot_id DESC;

-- Never mix currencies implicitly. Currency conversion must be introduced as a
-- separate, dated FX layer before cross-currency household totals are computed.
CREATE OR REPLACE VIEW analytics.v_current_household_income_by_currency AS
SELECT
  household_id,
  currency,
  COALESCE(SUM(annual_gross_income), 0)::NUMERIC(20,2) AS annual_gross_income,
  COALESCE(SUM(monthly_net_income), 0)::NUMERIC(20,2) AS monthly_net_income,
  COUNT(*) FILTER (WHERE employment_status IN ('employed', 'self_employed')) AS earning_adult_count,
  COUNT(*) AS tracked_adult_count,
  MAX(as_of_date) AS latest_as_of_date
FROM analytics.v_current_employment
GROUP BY household_id, currency;
