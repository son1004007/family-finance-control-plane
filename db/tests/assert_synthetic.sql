DO $$
DECLARE
  actual NUMERIC;
BEGIN
  SELECT net_cash_flow INTO actual
  FROM analytics.v_monthly_cash_flow f
  JOIN finance.households h ON h.household_id = f.household_id
  WHERE h.label = 'synthetic_household'
    AND f.month = DATE '2026-01-01'
    AND f.currency = 'KRW';

  IF actual IS DISTINCT FROM 2350000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic net cash flow: %', actual;
  END IF;
END
$$;

DO $$
DECLARE
  actual NUMERIC;
BEGIN
  SELECT net_worth INTO actual
  FROM analytics.v_net_worth_by_currency n
  JOIN finance.households h ON h.household_id = n.household_id
  WHERE h.label = 'synthetic_household'
    AND n.currency = 'KRW';

  IF actual IS DISTINCT FROM 15000000::numeric THEN
    RAISE EXCEPTION 'unexpected synthetic net worth: %', actual;
  END IF;
END
$$;

DO $$
DECLARE
  actual NUMERIC;
BEGIN
  SELECT monthly_fixed_obligations INTO actual
  FROM analytics.v_active_recurring_obligations o
  JOIN finance.households h ON h.household_id = o.household_id
  WHERE h.label = 'synthetic_household'
    AND o.currency = 'KRW';

  IF actual IS DISTINCT FROM 300000::numeric THEN
    RAISE EXCEPTION 'unexpected recurring obligations: %', actual;
  END IF;
END
$$;

DO $$
DECLARE
  annual_gross NUMERIC;
  monthly_net NUMERIC;
  earners BIGINT;
  tracked BIGINT;
BEGIN
  SELECT
    i.annual_gross_income,
    i.monthly_net_income,
    i.earning_adult_count,
    i.tracked_adult_count
  INTO annual_gross, monthly_net, earners, tracked
  FROM analytics.v_current_household_income_by_currency i
  JOIN finance.households h ON h.household_id = i.household_id
  WHERE h.label = 'synthetic_household'
    AND i.currency = 'KRW';

  IF annual_gross IS DISTINCT FROM 60000000::numeric THEN
    RAISE EXCEPTION 'unexpected current annual gross income: %', annual_gross;
  END IF;
  IF monthly_net IS DISTINCT FROM 5200000::numeric THEN
    RAISE EXCEPTION 'unexpected current monthly net income: %', monthly_net;
  END IF;
  IF earners IS DISTINCT FROM 1::bigint THEN
    RAISE EXCEPTION 'unexpected earning adult count: %', earners;
  END IF;
  IF tracked IS DISTINCT FROM 2::bigint THEN
    RAISE EXCEPTION 'unexpected tracked adult count: %', tracked;
  END IF;
END
$$;

SELECT 'SYNTHETIC_ASSERTIONS=PASS' AS result;
