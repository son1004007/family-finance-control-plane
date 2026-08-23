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
  actual INTEGER;
BEGIN
  SELECT COUNT(*) INTO actual FROM meta.schema_migrations;
  IF actual <> 3 THEN
    RAISE EXCEPTION 'expected 3 applied migrations, got %', actual;
  END IF;
END
$$;

SELECT 'SYNTHETIC_ASSERTIONS=PASS' AS result;
