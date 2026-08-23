# Deterministic metric semantics

Core financial totals are computed in PostgreSQL so different AI clients receive the same numeric answer.

## Currency boundary

Every metric is grouped by currency. No FX conversion is implicit.

## Current metrics

- `analytics.v_monthly_spending_by_category`: absolute outflow for negative transactions, grouped by calendar month and category.
- `analytics.v_liquid_reserve_by_currency`: latest account balances plus the `liquid_value` portion of non-account asset snapshots. Do not also represent the same bank balance as an asset snapshot.
- `analytics.v_monthly_cash_flow_calendar`: monthly inflow, outflow and net cash flow with zero-filled months between the first and latest observed transaction month.
- `analytics.v_rolling_cash_flow`: trailing 3/6/12 calendar-month net cash flow. `history_months` indicates how much history exists at that point.
- `planning.income_benchmarks`: versioned target income values with an explicit `gross` or `net` basis.
- `analytics.v_current_income_gap_to_benchmark`: non-negative annual gap between the latest active benchmark and current DB-backed employment income using the same basis.
- `analytics.v_household_financial_snapshot_by_currency`: current gross income, monthly net income, fixed obligations, fixed-cost headroom, net worth and liquid reserve.

## Important distinction

`fixed_cost_headroom = monthly_net_income - monthly_fixed_obligations` is not the same as free cash flow. Actual free cash flow should be derived from transaction history once sufficient recurring transaction data has been imported and reconciled.
