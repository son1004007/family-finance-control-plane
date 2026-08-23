# PostgreSQL Runtime Contract

The public runtime is intentionally generic. Household-specific paths, credentials and network details belong outside this repository.

## Version

The reference runtime uses PostgreSQL `16.15` via the Docker Official Image `postgres:16.15-alpine`.

## Default isolation

`compose.yaml` does not publish PostgreSQL port 5432 to the host. The database is reachable only inside the Compose network by default.

This is deliberate. External AI/database access is a later opt-in step and should use an approved private path rather than exposing PostgreSQL directly to a LAN or the Internet.

## Start locally

Set the admin password outside Git, then start the database:

```bash
export POSTGRES_ADMIN_PASSWORD='replace-with-local-secret'
docker compose up -d db
sh scripts/migrate_compose.sh
```

Do not put the real password in tracked shell scripts or documentation.

## Schemas

- `ingest`: import batches and raw-row normalization metadata
- `finance`: normalized household finance facts
- `planning`: goals and scenario inputs
- `analytics`: deterministic views
- `meta`: migration state

## Role model

Database migrations create NOLOGIN group roles:

- `finance_app`: application/importer read-write role
- `finance_ai_reader`: default AI query role; read-only
- `finance_ai_writer`: inherits reader access and may modify `planning` only

Actual LOGIN roles and passwords are provisioned in the private runtime later. They are not stored in public Git.

## Migration behavior

`scripts/migrate_compose.sh`:

1. creates the migration ledger if missing;
2. computes SHA-256 for each ordered SQL migration;
3. applies each migration once inside a transaction;
4. records its checksum;
5. rejects a previously applied migration whose content was modified.

Applied migrations should therefore be immutable. Schema changes are new migration files.

## Backup behavior

`scripts/backup_postgres_compose.sh` creates a PostgreSQL custom-format logical dump, restores it into an isolated temporary database, compares representative table counts, and only then reports success.

The production database is never dropped or overwritten by the verification step.

A host-specific deployment should place verified dump files outside the live PostgreSQL data volume and protect them with an off-device backup mechanism where possible.

## Currency rule

The initial analytics do not convert currencies. Views group financial totals by currency to avoid silently combining KRW, USD or other currencies at an undefined exchange rate. FX conversion can be added later as a separate, explicitly sourced dataset.
