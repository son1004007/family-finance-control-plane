DO $$
DECLARE
  jan_net NUMERIC;
  feb_net NUMERIC;
  feb_change NUMERIC;
  coverage NUMERIC;
  reserve NUMERIC;
BEGIN
  SELECT n.net_worth INTO jan_net
  FROM analytics.v_net_worth_history_by_currency n
  JOIN finance.households h USING(household_id)
  WHERE h.label='synthetic_household' AND n.currency='KRW' AND n.month=DATE '2026-01-01';

  SELECT n.net_worth, n.net_worth_change INTO feb_net, feb_change
  FROM analytics.v_net_worth_history_by_currency n
  JOIN finance.households h USING(household_id)
  WHERE h.label='synthetic_household' AND n.currency='KRW' AND n.month=DATE '2026-02-01';

  IF jan_net IS DISTINCT FROM 15000000::numeric THEN
    RAISE EXCEPTION 'unexpected Jan net worth: %', jan_net;
  END IF;
  IF feb_net IS DISTINCT FROM 18000000::numeric OR feb_change IS DISTINCT FROM 3000000::numeric THEN
    RAISE EXCEPTION 'unexpected Feb net worth/change: % / %', feb_net, feb_change;
  END IF;

  SELECT e.liquid_reserve, e.coverage_months INTO reserve, coverage
  FROM analytics.v_emergency_reserve_coverage e
  JOIN finance.households h USING(household_id)
  WHERE h.label='synthetic_household' AND e.currency='KRW';

  IF reserve IS DISTINCT FROM 30000000::numeric OR coverage IS DISTINCT FROM 100::numeric THEN
    RAISE EXCEPTION 'unexpected reserve/coverage: % / %', reserve, coverage;
  END IF;
END
$$;

SET ROLE finance_mcp_reader;
SELECT COUNT(*) FROM analytics.v_household_directory;
SELECT COUNT(*) FROM analytics.v_household_financial_snapshot_by_currency;
SELECT COUNT(*) FROM analytics.v_net_worth_history_by_currency;
SELECT COUNT(*) FROM analytics.v_emergency_reserve_coverage;
RESET ROLE;
