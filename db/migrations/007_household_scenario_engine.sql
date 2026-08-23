BEGIN;

ALTER TABLE planning.career_scenarios
  ADD COLUMN IF NOT EXISTS currency CHAR(3) NOT NULL DEFAULT 'KRW';
ALTER TABLE planning.career_scenarios
  DROP CONSTRAINT IF EXISTS career_scenarios_currency_check;
ALTER TABLE planning.career_scenarios
  ADD CONSTRAINT career_scenarios_currency_check CHECK (currency ~ '^[A-Z]{3}$');

ALTER TABLE planning.housing_candidates
  ADD COLUMN IF NOT EXISTS currency CHAR(3) NOT NULL DEFAULT 'KRW';
ALTER TABLE planning.housing_candidates
  DROP CONSTRAINT IF EXISTS housing_candidates_currency_check;
ALTER TABLE planning.housing_candidates
  ADD CONSTRAINT housing_candidates_currency_check CHECK (currency ~ '^[A-Z]{3}$');

ALTER TABLE planning.career_scenarios
  ADD CONSTRAINT uq_career_scenario_household_role_currency
  UNIQUE (household_id, adult_role_label, career_scenario_id, currency);

ALTER TABLE planning.housing_candidates
  ADD CONSTRAINT uq_housing_candidate_household_currency
  UNIQUE (household_id, housing_candidate_id, currency);

CREATE TABLE planning.household_scenarios (
  household_scenario_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  scenario_label TEXT NOT NULL,
  housing_candidate_id BIGINT,
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  monthly_childcare_cost NUMERIC(20,2) NOT NULL DEFAULT 0 CHECK (monthly_childcare_cost >= 0),
  monthly_household_services_cost NUMERIC(20,2) NOT NULL DEFAULT 0 CHECK (monthly_household_services_cost >= 0),
  monthly_other_operating_cost NUMERIC(20,2) NOT NULL DEFAULT 0 CHECK (monthly_other_operating_cost >= 0),
  childcare_risk_score SMALLINT CHECK (childcare_risk_score BETWEEN 1 AND 5),
  assumptions JSONB NOT NULL DEFAULT '{}'::jsonb,
  notes TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, scenario_label),
  UNIQUE (household_id, household_scenario_id, currency),
  CHECK (currency ~ '^[A-Z]{3}$'),
  FOREIGN KEY (household_id, housing_candidate_id, currency)
    REFERENCES planning.housing_candidates(household_id, housing_candidate_id, currency)
);

CREATE TABLE planning.household_scenario_careers (
  household_scenario_career_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  household_scenario_id BIGINT NOT NULL,
  adult_role_label TEXT NOT NULL,
  career_scenario_id BIGINT NOT NULL,
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_scenario_id, adult_role_label),
  CHECK (currency ~ '^[A-Z]{3}$'),
  FOREIGN KEY (household_id, household_scenario_id, currency)
    REFERENCES planning.household_scenarios(household_id, household_scenario_id, currency)
    ON DELETE CASCADE,
  FOREIGN KEY (household_id, adult_role_label, career_scenario_id, currency)
    REFERENCES planning.career_scenarios(household_id, adult_role_label, career_scenario_id, currency)
);

CREATE OR REPLACE VIEW analytics.v_household_scenario_outcomes AS
WITH career_rollup AS (
  SELECT
    hs.household_scenario_id,
    hs.household_id,
    hs.currency,
    COUNT(hsc.household_scenario_career_id) AS selected_career_count,
    COUNT(*) FILTER (WHERE cs.annual_gross_income IS NULL) AS missing_gross_income_count,
    COUNT(*) FILTER (WHERE cs.annual_net_income IS NULL) AS missing_net_income_count,
    COUNT(*) FILTER (WHERE cs.monthly_commute_cost IS NULL) AS missing_commute_cost_count,
    COUNT(*) FILTER (
      WHERE cs.commute_minutes_one_way IS NULL OR cs.work_days_per_week IS NULL
    ) AS missing_commute_time_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE cs.annual_gross_income IS NULL) > 0 THEN NULL
      ELSE COALESCE(SUM(cs.annual_gross_income), 0)
    END::NUMERIC(20,2) AS annual_gross_income,
    CASE
      WHEN COUNT(*) FILTER (WHERE cs.annual_net_income IS NULL) > 0 THEN NULL
      ELSE COALESCE(SUM(cs.annual_net_income), 0)
    END::NUMERIC(20,2) AS annual_net_income,
    CASE
      WHEN COUNT(*) FILTER (WHERE cs.monthly_commute_cost IS NULL) > 0 THEN NULL
      ELSE COALESCE(SUM(cs.monthly_commute_cost), 0)
    END::NUMERIC(20,2) AS monthly_commute_cost,
    CASE
      WHEN COUNT(*) FILTER (
        WHERE cs.commute_minutes_one_way IS NULL OR cs.work_days_per_week IS NULL
      ) > 0 THEN NULL
      ELSE COALESCE(SUM(cs.commute_minutes_one_way * 2 * cs.work_days_per_week), 0)
    END::NUMERIC(20,2) AS commute_minutes_per_week
  FROM planning.household_scenarios hs
  LEFT JOIN planning.household_scenario_careers hsc
    ON hsc.household_scenario_id = hs.household_scenario_id
  LEFT JOIN planning.career_scenarios cs
    ON cs.career_scenario_id = hsc.career_scenario_id
  GROUP BY hs.household_scenario_id, hs.household_id, hs.currency
),
scenario_base AS (
  SELECT
    hs.household_scenario_id,
    hs.household_id,
    hs.scenario_label,
    hs.currency,
    hs.childcare_risk_score,
    hs.monthly_childcare_cost,
    hs.monthly_household_services_cost,
    hs.monthly_other_operating_cost,
    hc.candidate_label AS housing_candidate_label,
    CASE
      WHEN hs.housing_candidate_id IS NULL THEN 0::NUMERIC
      ELSE hc.monthly_housing_cost
    END::NUMERIC(20,2) AS monthly_housing_cost,
    CASE
      WHEN hs.housing_candidate_id IS NULL THEN 0::NUMERIC
      ELSE hc.required_cash
    END::NUMERIC(20,2) AS required_housing_cash,
    cr.selected_career_count,
    cr.missing_gross_income_count,
    cr.missing_net_income_count,
    cr.missing_commute_cost_count,
    cr.missing_commute_time_count,
    cr.annual_gross_income,
    cr.annual_net_income,
    cr.monthly_commute_cost,
    cr.commute_minutes_per_week,
    hs.assumptions,
    hs.active
  FROM planning.household_scenarios hs
  JOIN career_rollup cr USING (household_scenario_id, household_id, currency)
  LEFT JOIN planning.housing_candidates hc
    ON hc.housing_candidate_id = hs.housing_candidate_id
   AND hc.household_id = hs.household_id
   AND hc.currency = hs.currency
)
SELECT
  sb.*,
  CASE
    WHEN sb.monthly_commute_cost IS NULL OR sb.monthly_housing_cost IS NULL THEN NULL
    ELSE (
      sb.monthly_commute_cost
      + sb.monthly_housing_cost
      + sb.monthly_childcare_cost
      + sb.monthly_household_services_cost
      + sb.monthly_other_operating_cost
    )::NUMERIC(20,2)
  END AS monthly_modeled_operating_cost,
  CASE
    WHEN sb.monthly_commute_cost IS NULL OR sb.monthly_housing_cost IS NULL THEN NULL
    ELSE 12 * (
      sb.monthly_commute_cost
      + sb.monthly_housing_cost
      + sb.monthly_childcare_cost
      + sb.monthly_household_services_cost
      + sb.monthly_other_operating_cost
    )
  END::NUMERIC(20,2) AS annual_modeled_operating_cost,
  CASE
    WHEN sb.annual_net_income IS NULL
      OR sb.monthly_commute_cost IS NULL
      OR sb.monthly_housing_cost IS NULL THEN NULL
    ELSE sb.annual_net_income - 12 * (
      sb.monthly_commute_cost
      + sb.monthly_housing_cost
      + sb.monthly_childcare_cost
      + sb.monthly_household_services_cost
      + sb.monthly_other_operating_cost
    )
  END::NUMERIC(20,2) AS annual_net_after_modeled_costs,
  lr.liquid_reserve AS current_liquid_reserve,
  CASE
    WHEN lr.liquid_reserve IS NULL OR sb.required_housing_cash IS NULL THEN NULL
    ELSE lr.liquid_reserve - sb.required_housing_cash
  END::NUMERIC(20,2) AS projected_liquid_reserve_after_housing
FROM scenario_base sb
LEFT JOIN analytics.v_liquid_reserve_by_currency lr
  ON lr.household_id = sb.household_id AND lr.currency = sb.currency;

COMMIT;
