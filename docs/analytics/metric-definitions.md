# Deterministic Metric Definitions

These definitions are part of the control-plane contract. AI clients explain the results; they do not silently redefine the formulas.

## Currency rule

No view converts or combines currencies. Every monetary result is partitioned by the recorded currency. FX conversion requires an explicit, dated conversion source and is outside the current core contract.

## Monthly cash flow

Source: normalized `finance.transactions`.

- `inflow = sum(amount where amount > 0)`
- `outflow = sum(abs(amount) where amount < 0)`
- `net_cash_flow = sum(amount)`
- `transaction_count = count(recorded transactions)`

A missing month in the calendar view is represented as zero recorded activity. This means "no recorded transactions", not "the household spent nothing" if source ingestion is incomplete.

## Monthly spending by category

Source: normalized negative transactions only.

- `spending = sum(abs(amount))`
- missing/blank category becomes an explicit uncategorized bucket in the upstream deterministic view.
- counterparties and descriptions are not exposed through the remote MCP spending tool.

## Current household income

Source: latest time-versioned `finance.employment_snapshots` for each person/currency.

- annual gross income is the sum of non-null current annual gross values.
- monthly net income is the sum of non-null current monthly net values.
- missing income inputs remain visible through counts/status rather than being guessed.

Realized transaction income and employment baseline income are intentionally separate concepts.

## Current net worth

For each account/asset/liability identity and currency, use its latest dated snapshot.

`net_worth = account balances + other asset market value - liability principal`

No FX conversion is performed.

## Monthly net-worth history

For every month between the first and latest available snapshot, each account/asset/liability identity carries forward its most recent snapshot known by the end of that month.

- `previous_month_net_worth = lag(net_worth)`
- `net_worth_change = net_worth - previous_month_net_worth`

This is a snapshot history, not a mark-to-market estimate. Stale underlying valuations remain stale until a newer snapshot is recorded.

## Liquid reserve

`liquid_reserve = latest account balances + latest asset liquid_value`

Asset market value is not automatically assumed liquid. Only the separately recorded `liquid_value` contributes.

## Active recurring obligations

`monthly_fixed_obligations = sum(active recurring obligation monthly_amount)`

An aggregate opening baseline may initially represent this amount. Later normalized obligations can replace/refine it through explicit dated records.

## Emergency reserve coverage

`coverage_months = liquid_reserve / monthly_fixed_obligations`

The metric is `NULL` rather than infinity/zero when a positive obligation basis is unavailable. `coverage_status` identifies why a value cannot be calculated.

## Income benchmark gap

`annual_income_gap = benchmark annual target - current annual household gross income`

A policy/statistical benchmark and employee salary are different accounting concepts. The view exposes the arithmetic comparison only; interpretation belongs in planning policy.

## Household scenario outcome

Scenario inputs are explicit records for career choices, housing, commute, childcare, household services and other operating costs.

Core formula:

```text
monthly_modeled_operating_cost
= monthly_commute_cost
+ monthly_housing_cost
+ monthly_childcare_cost
+ monthly_household_services_cost
+ monthly_other_operating_cost

annual_net_after_modeled_costs
= annual_net_income
- (monthly_modeled_operating_cost * 12)
```

Missing required scenario inputs propagate as missing outcome fields. The engine does not convert unknown values to zero.

`projected_liquid_reserve_after_housing = current_liquid_reserve - required_housing_cash`

Childcare risk and other qualitative constraints are explicit planning inputs; the AI is not allowed to invent probabilistic scores.

## Provenance rule

Every imported source batch records source type/name, original filename, original-file SHA-256, mapping SHA-256, normalizer version, row/error counts and completion status. Source rows retain a row hash and normalization status.

A mapping may also declare deterministic reconciliation expectations. A reconciliation mismatch marks the batch failed and prevents normalized transaction writes while retaining provenance for diagnosis.
