# Family Finance Control Plane

A self-hosted reference architecture for giving multiple AI clients a shared, evidence-backed view of household finance without relying on chat memory.

## Core separation

```text
Public GitHub
  reusable code / schema / docs / synthetic examples
        |
Private policy overlay
  household-specific decision rules and private planning context
        |
PostgreSQL + storage
  current income / balances / transactions / assets / liabilities
        |
AI clients
  direct SQL and/or MCP/API adapters
```

## Design principles

- GitHub stores code and decision-system definitions, not raw financial records.
- PostgreSQL is the Source of Truth for changing financial facts.
- AI may query PostgreSQL directly when the runtime allows it.
- Public examples are synthetic and reproducible.
- Private planning context is isolated from the public repository.
- Credentials and raw financial exports never belong in Git.

## Planned capabilities

- CSV/XLSX financial import and normalization
- income, account, asset, liability and transaction models
- monthly cash-flow and net-worth analytics
- scenario analysis for employment, housing, childcare and commuting
- read-only AI SQL access with optional controlled write roles
- MCP/API adapter for AI clients that cannot access PostgreSQL directly
- sanitized build-log documentation so others can reproduce the system

## Privacy model

This public repository intentionally contains no real household financial values or identifying details. All documentation and test fixtures must use fictional values, role labels and synthetic locations.
