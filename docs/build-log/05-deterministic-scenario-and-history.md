# 05. Deterministic Scenario and Historical Analytics

The useful question is not "what did the AI guess?" but "which inputs and formulas produced this household outcome?"

This stage moved two categories of reasoning into PostgreSQL:

1. dated financial history;
2. career/housing/childcare scenario composition.

## Historical net worth

Account balances, asset valuations and liability balances are snapshots. The history view carries each entity's latest known snapshot forward to the end of each month and then calculates:

```text
net worth = accounts + assets - liabilities
monthly change = current month - previous month
```

The view does not invent price changes between snapshots and does not combine currencies.

## Emergency reserve

Liquid reserve uses account balances plus explicit asset `liquid_value`. Market value is not assumed liquid.

```text
coverage months = liquid reserve / active monthly recurring obligations
```

If a positive obligation basis is unavailable, the result remains missing with an explicit status instead of becoming zero or infinity.

## Scenario composition

Career choices, housing candidates, commute, childcare and additional household operating costs are stored as explicit planning records. A deterministic view combines them and calculates net annual outcome.

Unknown values remain unknown. This is important: an AI agent cannot improve a scenario by silently treating an unknown childcare or commute cost as zero.

## Why this belongs in SQL

- every AI client receives the same arithmetic;
- formulas are reviewable without inspecting prompts;
- changes are testable with fictional fixtures;
- missing-data semantics are explicit;
- scenario explanations can cite source fields rather than model intuition.

The synthetic CI fixture includes two dated net-worth snapshots and a fictional dual-income/housing scenario so regressions are detected without publishing household data.
