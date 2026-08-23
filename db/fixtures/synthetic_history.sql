-- Entirely fictional second-month snapshots for deterministic history tests.
INSERT INTO finance.account_balance_snapshots(account_id, balance_at, balance, currency)
SELECT account_id, TIMESTAMPTZ '2026-02-28 23:59:59+09',
       CASE account_label WHEN 'synthetic_checking' THEN 13000000 ELSE 9000000 END,
       'KRW'
FROM finance.accounts
WHERE account_label IN ('synthetic_checking', 'synthetic_savings');

INSERT INTO finance.asset_snapshots(
  household_id, owner_person_id, asset_type, asset_label, valued_at,
  market_value, liquid_value, currency
)
SELECT h.household_id, p.person_id, 'vehicle', 'synthetic_vehicle',
       TIMESTAMPTZ '2026-02-28 23:59:59+09', 14000000, 8000000, 'KRW'
FROM finance.households h
JOIN finance.persons p ON p.household_id=h.household_id AND p.role_label='adult_1'
WHERE h.label='synthetic_household';

INSERT INTO finance.liability_snapshots(
  household_id, owner_person_id, liability_type, liability_label, valued_at,
  principal_balance, monthly_payment, annual_interest_rate, currency
)
SELECT h.household_id, p.person_id, 'loan', 'synthetic_loan',
       TIMESTAMPTZ '2026-02-28 23:59:59+09', 18000000, 500000, 0.045, 'KRW'
FROM finance.households h
JOIN finance.persons p ON p.household_id=h.household_id AND p.role_label='adult_1'
WHERE h.label='synthetic_household';
