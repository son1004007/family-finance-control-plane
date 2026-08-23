# Adding a Private PostgreSQL Ledger for AI-Assisted Household Finance

The first implementation milestone protects public Git from private data. The next milestone gives every approved AI client one database-backed source of financial truth.

This build uses PostgreSQL rather than chat memory, spreadsheets embedded in prompts, or a private Git repository as the transaction ledger.

## Design goals

The database foundation must provide:

- persistent finance data independent of application redeploys;
- deterministic SQL calculations;
- a read-only role for normal AI analysis;
- a separately controlled write role;
- migrations that detect accidental edits to already-applied files;
- verified backup and restore rather than an untested dump file;
- no public database port by default.

## Why PostgreSQL 16

The reference implementation uses a currently supported PostgreSQL 16 patch release and the Docker Official Image. A pinned patch-level image makes local/CI behavior easier to reproduce while keeping upgrades explicit.

## Data layers

```text
source exports
    |
    v
ingest schema
    |
    v
finance schema
    |
    +----> analytics views ----> AI SQL
    |
    +----> planning schema ----> scenario analysis
```

`ingest` keeps provenance and normalization metadata. `finance` is the canonical ledger. `analytics` contains calculations that should return the same number regardless of which AI asks the question. `planning` stores structured what-if inputs separately from historical facts.

## AI permissions

Three NOLOGIN group roles are created by migration:

```text
finance_app
finance_ai_reader
finance_ai_writer
```

The default reader can select finance/planning/analytics objects but cannot insert or update them. The optional writer inherits read access and is initially limited to the `planning` schema, so a scenario automation cannot silently rewrite the historical ledger.

Real LOGIN users and passwords are runtime concerns and are intentionally excluded from public Git.

## Migrations

A small migration runner stores the filename and SHA-256 checksum of every applied migration. Re-running an unchanged migration is a no-op. Modifying a migration after it has been applied is treated as an error; create a new migration instead.

This avoids a common failure mode in small self-hosted projects where an old SQL file is edited and different machines silently end up with different schemas.

## Synthetic verification

The public test fixture contains only fictional accounts, balances, income, expenses, assets and debt. CI calculates known expected values from those rows and fails if the SQL views drift.

The same CI also proves that:

- the AI reader can query analytics;
- the AI reader cannot write planning data;
- the controlled AI writer can write planning data;
- that writer still cannot mutate the finance ledger.

## Backup is not complete until restore succeeds

The backup script uses PostgreSQL custom-format `pg_dump`, then restores the archive into a temporary database and compares representative row counts. The live database is not replaced during verification.

This turns “a dump file exists” into “this dump was restorable at the time it was created.”

A later deployment can put those verified dumps on NAS storage and copy them to a second device/cloud/off-site destination for disaster recovery.

## Reproducing the foundation

A developer only needs Docker Compose and a local secret:

```bash
export POSTGRES_ADMIN_PASSWORD='local-development-only'
docker compose up -d db
sh scripts/migrate_compose.sh
```

The public repository remains safe to clone because all household-specific rows, credentials and infrastructure overrides remain outside it.
