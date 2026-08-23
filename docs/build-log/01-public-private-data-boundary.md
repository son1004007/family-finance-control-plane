# Building a Family Finance AI: Public Code, Private Policy, Data Outside Git

A personal-finance AI project has an unusual requirement: the implementation should be reproducible, while the actual financial facts must remain private.

This project uses three data classes instead of treating a private Git repository as a financial database.

## 1. PUBLIC: reusable implementation

The public repository contains:

- application code
- database schema and migrations
- generic CSV/XLSX importers
- synthetic sample data
- SQL examples using fictional values
- architecture and deployment documentation
- AI integration examples

Any example household, salary, asset, location or transaction in public documentation must be fictional.

## 2. PRIVATE-GIT: household-specific policy

A separate private repository contains information that helps AI agents understand household decision rules without exposing them publicly, such as:

- financial decision policies
- housing/career/childcare constraints
- private scenario definitions
- dated planning snapshots

It still does not act as the transaction ledger.

## 3. DATA-ONLY: PostgreSQL and private storage

Changing financial facts belong outside Git:

- current income
- transactions
- account balances
- assets and liabilities
- recurring expenses
- raw bank/card/security exports

PostgreSQL becomes the Source of Truth for normalized facts, while private storage keeps raw imports and backups.

Secrets are managed separately and are never committed.

## Why not store everything in private GitHub?

A private repository reduces visibility but does not solve the core problems:

- financial records change frequently;
- raw exports may contain identifiers and transaction descriptions;
- Git history makes accidental secret/data removal harder;
- databases provide better querying, constraints, backups and audit controls.

Private Git is therefore used for policy and configuration, not as the ledger.

## AI access model

AI clients can use either:

```text
AI -> PostgreSQL (direct SQL)
```

or:

```text
AI -> MCP/API adapter -> PostgreSQL
```

Direct SQL is useful for capable development agents. A read-only database role should be the default, with a separate controlled writer role for approved automation.

## Publication workflow

When a useful lesson comes from private operation:

1. create a new public document instead of copying the private one;
2. replace names with role labels;
3. replace real financial values with synthetic values;
4. replace real locations with generic placeholders;
5. remove account identifiers, transaction descriptions and credentials;
6. review the Git diff;
7. publish only the sanitized derivative.

This allows the implementation process to become a reproducible public build log while the household's actual finances remain outside the public repository.
