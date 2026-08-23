-- Entirely fictional benchmark used only for deterministic analytics tests.
INSERT INTO planning.income_benchmarks(
  household_id,
  benchmark_label,
  income_basis,
  annual_target_income,
  currency,
  effective_on,
  source_label,
  notes
)
SELECT
  household_id,
  'synthetic_household_income_target',
  'gross',
  72000000,
  'KRW',
  DATE '2026-01-01',
  'synthetic_fixture',
  'Fictional benchmark for public CI only.'
FROM finance.households
WHERE label = 'synthetic_household';
