-- Entirely fictional scenario fixture for public CI.
INSERT INTO planning.career_scenarios(
  household_id,
  scenario_label,
  adult_role_label,
  annual_gross_income,
  annual_net_income,
  commute_minutes_one_way,
  monthly_commute_cost,
  work_days_per_week,
  currency,
  assumptions
)
SELECT
  household_id,
  'synthetic_primary_job',
  'adult_1',
  60000000,
  52000000,
  30,
  100000,
  5,
  'KRW',
  '{"fixture":true}'::jsonb
FROM finance.households
WHERE label = 'synthetic_household'
ON CONFLICT (household_id, scenario_label, adult_role_label) DO NOTHING;

UPDATE planning.career_scenarios cs
SET currency = 'KRW'
FROM finance.households h
WHERE cs.household_id = h.household_id
  AND h.label = 'synthetic_household'
  AND cs.scenario_label = 'synthetic_return_to_work'
  AND cs.adult_role_label = 'adult_2';

INSERT INTO planning.housing_candidates(
  household_id,
  candidate_label,
  housing_type,
  required_cash,
  monthly_housing_cost,
  location_label,
  currency,
  attributes
)
SELECT
  household_id,
  'synthetic_family_home',
  'rental',
  100000000,
  800000,
  'synthetic_area',
  'KRW',
  '{"fixture":true}'::jsonb
FROM finance.households
WHERE label = 'synthetic_household'
ON CONFLICT (household_id, candidate_label) DO NOTHING;

INSERT INTO planning.household_scenarios(
  household_id,
  scenario_label,
  housing_candidate_id,
  currency,
  monthly_childcare_cost,
  monthly_household_services_cost,
  monthly_other_operating_cost,
  childcare_risk_score,
  assumptions,
  notes
)
SELECT
  h.household_id,
  'synthetic_dual_income_move',
  hc.housing_candidate_id,
  'KRW',
  500000,
  200000,
  100000,
  2,
  '{"fixture":true}'::jsonb,
  'Fictional scenario for deterministic CI only.'
FROM finance.households h
JOIN planning.housing_candidates hc
  ON hc.household_id = h.household_id
 AND hc.candidate_label = 'synthetic_family_home'
WHERE h.label = 'synthetic_household'
ON CONFLICT (household_id, scenario_label) DO NOTHING;

INSERT INTO planning.household_scenario_careers(
  household_id,
  household_scenario_id,
  adult_role_label,
  career_scenario_id,
  currency
)
SELECT
  hs.household_id,
  hs.household_scenario_id,
  cs.adult_role_label,
  cs.career_scenario_id,
  'KRW'
FROM planning.household_scenarios hs
JOIN finance.households h ON h.household_id = hs.household_id
JOIN planning.career_scenarios cs
  ON cs.household_id = hs.household_id
 AND cs.scenario_label IN ('synthetic_primary_job', 'synthetic_return_to_work')
WHERE h.label = 'synthetic_household'
  AND hs.scenario_label = 'synthetic_dual_income_move'
ON CONFLICT (household_scenario_id, adult_role_label) DO NOTHING;
