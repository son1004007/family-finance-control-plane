-- Entirely fictional fixture for CI and public documentation.
INSERT INTO ingest.import_batches(source_type, source_name, original_filename, file_sha256, status, row_count, completed_at)
VALUES ('synthetic', 'fixture', 'synthetic-fixture.csv', repeat('f', 64), 'completed', 4, now());

INSERT INTO finance.households(label, base_currency)
VALUES ('synthetic_household', 'KRW');

INSERT INTO finance.persons(household_id, role_label)
SELECT household_id, role_label
FROM finance.households
CROSS JOIN (VALUES ('adult_1'), ('adult_2')) AS roles(role_label)
WHERE label = 'synthetic_household';

INSERT INTO finance.institutions(institution_type, display_label)
VALUES ('bank', 'synthetic_bank');

INSERT INTO finance.accounts(household_id, owner_person_id, institution_id, account_type, account_label, currency)
SELECT h.household_id, p.person_id, i.institution_id, x.account_type, x.account_label, 'KRW'
FROM finance.households h
JOIN finance.persons p ON p.household_id = h.household_id AND p.role_label = 'adult_1'
CROSS JOIN finance.institutions i
CROSS JOIN (VALUES
  ('checking', 'synthetic_checking'),
  ('savings', 'synthetic_savings')
) AS x(account_type, account_label)
WHERE h.label = 'synthetic_household'
  AND i.display_label = 'synthetic_bank';

INSERT INTO finance.account_balance_snapshots(account_id, balance_at, balance, currency)
SELECT account_id, TIMESTAMPTZ '2026-01-31 23:59:59+09',
       CASE account_label WHEN 'synthetic_checking' THEN 12000000 ELSE 8000000 END,
       'KRW'
FROM finance.accounts
WHERE account_label IN ('synthetic_checking', 'synthetic_savings');

INSERT INTO finance.transactions(account_id, occurred_at, amount, currency, category, description, source_row_hash)
SELECT a.account_id, x.occurred_at, x.amount, 'KRW', x.category, x.description, x.source_row_hash
FROM finance.accounts a
CROSS JOIN (VALUES
  (TIMESTAMPTZ '2026-01-10 09:00:00+09',  5200000::numeric, 'income',    'synthetic salary', repeat('a', 64)),
  (TIMESTAMPTZ '2026-01-12 09:00:00+09', -1500000::numeric, 'housing',   'synthetic housing cost', repeat('b', 64)),
  (TIMESTAMPTZ '2026-01-18 09:00:00+09', -1100000::numeric, 'living',    'synthetic living cost', repeat('c', 64)),
  (TIMESTAMPTZ '2026-01-22 09:00:00+09',  -250000::numeric, 'transport', 'synthetic transport', repeat('d', 64))
) AS x(occurred_at, amount, category, description, source_row_hash)
WHERE a.account_label = 'synthetic_checking';

INSERT INTO finance.income_events(household_id, person_id, occurred_on, income_type, gross_amount, net_amount, currency, recurring)
SELECT h.household_id, p.person_id, DATE '2026-01-10', 'salary', 6000000, 5200000, 'KRW', true
FROM finance.households h
JOIN finance.persons p ON p.household_id = h.household_id AND p.role_label = 'adult_1'
WHERE h.label = 'synthetic_household';

INSERT INTO finance.asset_snapshots(household_id, owner_person_id, asset_type, asset_label, valued_at, market_value, liquid_value, currency)
SELECT h.household_id, p.person_id, 'vehicle', 'synthetic_vehicle', TIMESTAMPTZ '2026-01-31 23:59:59+09', 15000000, 10000000, 'KRW'
FROM finance.households h
JOIN finance.persons p ON p.household_id = h.household_id AND p.role_label = 'adult_1'
WHERE h.label = 'synthetic_household';

INSERT INTO finance.liability_snapshots(household_id, owner_person_id, liability_type, liability_label, valued_at, principal_balance, monthly_payment, annual_interest_rate, currency)
SELECT h.household_id, p.person_id, 'loan', 'synthetic_loan', TIMESTAMPTZ '2026-01-31 23:59:59+09', 20000000, 500000, 0.045, 'KRW'
FROM finance.households h
JOIN finance.persons p ON p.household_id = h.household_id AND p.role_label = 'adult_1'
WHERE h.label = 'synthetic_household';

INSERT INTO finance.recurring_obligations(household_id, label, category, monthly_amount, currency, starts_on)
SELECT household_id, 'synthetic_insurance', 'insurance', 300000, 'KRW', DATE '2026-01-01'
FROM finance.households
WHERE label = 'synthetic_household';

INSERT INTO planning.goals(household_id, goal_type, label, target_amount, target_currency, priority)
SELECT household_id, 'emergency_fund', 'synthetic_emergency_fund', 30000000, 'KRW', 1
FROM finance.households
WHERE label = 'synthetic_household';

INSERT INTO planning.career_scenarios(household_id, scenario_label, adult_role_label, annual_gross_income, annual_net_income, commute_minutes_one_way, monthly_commute_cost, work_days_per_week)
SELECT household_id, 'synthetic_return_to_work', 'adult_2', 36000000, 30000000, 35, 90000, 5
FROM finance.households
WHERE label = 'synthetic_household';
