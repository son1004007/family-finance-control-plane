# Household scenario engine

The scenario engine combines career, housing and household operating assumptions without asking an LLM to perform the arithmetic.

## Inputs

A `planning.household_scenarios` row selects one housing candidate and stores explicit scenario-level costs:

- childcare;
- household services/meals or other support required by the scenario;
- other modeled operating cost;
- an optional childcare risk score from 1 to 5.

`planning.household_scenario_careers` selects at most one career scenario per adult role. Database foreign keys ensure the selected career belongs to the same household, adult role and currency as the household scenario.

Career and housing planning records now carry an explicit currency. The scenario engine never combines currencies implicitly.

## Output

`analytics.v_household_scenario_outcomes` computes:

- selected career count;
- annual gross and net scenario income;
- monthly commute cost;
- weekly round-trip commute minutes;
- monthly and annual modeled operating cost;
- annual net income after modeled costs;
- required housing cash;
- current liquid reserve when a reconciled baseline exists;
- projected liquid reserve after required housing cash;
- explicit childcare risk score.

## Missing values

Unknown income, commute or housing cost is not silently converted to zero. When a required selected component is unknown, the corresponding aggregate becomes `NULL` and missing-value counters identify the incomplete inputs.

A scenario with no housing candidate treats scenario housing cost and required housing cash as zero. A selected housing candidate with unknown monthly cost or required cash remains unknown.

## Interpretation boundary

`annual_net_after_modeled_costs` is **not household free cash flow**. It subtracts only the costs explicitly modeled by the scenario. Existing living expenses, taxes not already reflected in annual net income, debt service or other baseline expenses are not automatically added unless they are explicitly modeled elsewhere.

`childcare_risk_score` is an input, not a calculated fact. An AI may explain why a supplied score matters, but it must not present the score as an objective probability.

This distinction keeps deterministic arithmetic separate from judgment.
