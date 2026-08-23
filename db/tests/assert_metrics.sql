DO $$
DECLARE
  spending NUMERIC;
  liquid_reserve NUMERIC;
  income_gap NUMERIC;
  fixed_headroom NUMERIC;
  rolling_3m NUMERIC;
BEGIN
  SELECT s.spending INTO spending
  FROM analytics.v_monthly_spending_by_category s
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household'
    AND s.month = DATE '2026-01-01'
    AND s.currency = 'KRW'
    AND s.category = 'housing';

  IF spending IS DISTINCT FROM 1500000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic housing spending: %', spending;
  END IF;

  SELECT l.liquid_reserve INTO liquid_reserve
  FROM analytics.v_liquid_reserve_by_currency l
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household' AND l.currency = 'KRW';

  IF liquid_reserve IS DISTINCT FROM 30000000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic liquid reserve: %', liquid_reserve;
  END IF;

  SELECT g.annual_income_gap INTO income_gap
  FROM analytics.v_current_income_gap_to_benchmark g
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household'
    AND g.currency = 'KRW'
    AND g.benchmark_label = 'synthetic_household_income_target';

  IF income_gap IS DISTINCT FROM 12000000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic income gap: %', income_gap;
  END IF;

  SELECT f.fixed_cost_headroom INTO fixed_headroom
  FROM analytics.v_household_financial_snapshot_by_currency f
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household' AND f.currency = 'KRW';

  IF fixed_headroom IS DISTINCT FROM 4900000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic fixed-cost headroom: %', fixed_headroom;
  END IF;

  SELECT r.rolling_3m_net_cash_flow INTO rolling_3m
  FROM analytics.v_rolling_cash_flow r
  JOIN finance.households h USING (household_id)
  WHERE h.label = 'synthetic_household'
    AND r.currency = 'KRW'
    AND r.month = DATE '2026-01-01';

  IF rolling_3m IS DISTINCT FROM 2350000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic rolling cash flow: %', rolling_3m;
  END IF;
END
$$;

SELECT 'DETERMINISTIC_METRICS=PASS' AS result;
