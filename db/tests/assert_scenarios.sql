DO $$
DECLARE
  selected_careers BIGINT;
  annual_gross NUMERIC;
  annual_net NUMERIC;
  monthly_cost NUMERIC;
  annual_cost NUMERIC;
  annual_after NUMERIC;
  commute_minutes NUMERIC;
  required_cash NUMERIC;
  projected_liquid NUMERIC;
  childcare_risk SMALLINT;
BEGIN
  SELECT
    o.selected_career_count,
    o.annual_gross_income,
    o.annual_net_income,
    o.monthly_modeled_operating_cost,
    o.annual_modeled_operating_cost,
    o.annual_net_after_modeled_costs,
    o.commute_minutes_per_week,
    o.required_housing_cash,
    o.projected_liquid_reserve_after_housing,
    o.childcare_risk_score
  INTO
    selected_careers,
    annual_gross,
    annual_net,
    monthly_cost,
    annual_cost,
    annual_after,
    commute_minutes,
    required_cash,
    projected_liquid,
    childcare_risk
  FROM analytics.v_household_scenario_outcomes o
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household'
    AND o.scenario_label = 'synthetic_dual_income_move'
    AND o.currency = 'KRW';

  IF selected_careers IS DISTINCT FROM 2::bigint THEN
    RAISE EXCEPTION 'unexpected selected career count: %', selected_careers;
  END IF;
  IF annual_gross IS DISTINCT FROM 96000000::numeric THEN
    RAISE EXCEPTION 'unexpected scenario gross income: %', annual_gross;
  END IF;
  IF annual_net IS DISTINCT FROM 82000000::numeric THEN
    RAISE EXCEPTION 'unexpected scenario net income: %', annual_net;
  END IF;
  IF monthly_cost IS DISTINCT FROM 1790000::numeric THEN
    RAISE EXCEPTION 'unexpected modeled monthly operating cost: %', monthly_cost;
  END IF;
  IF annual_cost IS DISTINCT FROM 21480000::numeric THEN
    RAISE EXCEPTION 'unexpected modeled annual operating cost: %', annual_cost;
  END IF;
  IF annual_after IS DISTINCT FROM 60520000::numeric THEN
    RAISE EXCEPTION 'unexpected annual net after modeled costs: %', annual_after;
  END IF;
  IF commute_minutes IS DISTINCT FROM 650::numeric THEN
    RAISE EXCEPTION 'unexpected weekly commute minutes: %', commute_minutes;
  END IF;
  IF required_cash IS DISTINCT FROM 100000000::numeric THEN
    RAISE EXCEPTION 'unexpected required housing cash: %', required_cash;
  END IF;
  IF projected_liquid IS DISTINCT FROM -70000000::numeric THEN
    RAISE EXCEPTION 'unexpected projected liquid reserve: %', projected_liquid;
  END IF;
  IF childcare_risk IS DISTINCT FROM 2::smallint THEN
    RAISE EXCEPTION 'unexpected childcare risk score: %', childcare_risk;
  END IF;
END
$$;

SELECT 'HOUSEHOLD_SCENARIO_ENGINE=PASS' AS result;
