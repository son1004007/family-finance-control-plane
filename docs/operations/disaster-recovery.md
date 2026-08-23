# Backup and Disaster Recovery

## Recovery objective

The finance control plane is rebuildable from:

1. public implementation code and migrations;
2. private runtime configuration/credentials kept outside Git;
3. the latest verified PostgreSQL logical backup;
4. retained raw financial exports when re-import is necessary.

The database, not chat history, is the Source of Truth for changing financial facts.

## Backup contract

`scripts/backup_postgres_compose.sh`:

1. checks PostgreSQL readiness;
2. creates a PostgreSQL custom-format logical dump;
3. creates an isolated temporary database;
4. restores the dump with `pg_restore --exit-on-error`;
5. compares migration/account/transaction/asset/liability row counts;
6. removes the verification database;
7. only then reports `POSTGRES_BACKUP_RESTORE=PASS`;
8. keeps the newest `BACKUP_KEEP` dumps (default 14).

A dump without a successful isolated restore is not considered a verified backup.

## Routine evidence

The database CI runs the same backup/isolated-restore contract against synthetic data. Private runtime deployment should run the same contract after migrations and before reporting deployment success.

## Full-loss recovery procedure

### 1. Stop writes/imports

Do not run import or planning writer tasks during recovery. Preserve failed storage before attempting repair.

### 2. Recreate runtime boundary

- obtain a clean checkout of the implementation;
- recreate the dedicated PostgreSQL service and its isolated storage path;
- restore runtime credentials from the private credential boundary or explicitly rotate them if loss is confirmed;
- do not weaken SSH/host-key/network controls as a recovery shortcut.

### 3. Select a verified backup

Prefer the newest dump with known successful restore evidence. Record its checksum before restore. Do not restore an unverified dump over the only remaining copy of data.

### 4. Restore into an isolated database first

Create a temporary database and run:

```text
pg_restore --no-owner --no-privileges --exit-on-error
```

Verify at minimum:
- `meta.schema_migrations` exists and has the expected count;
- finance schema/tables exist;
- account, transaction, asset and liability counts are plausible;
- deterministic analytics views can query successfully.

### 5. Restore production database

Only after the isolated check passes, restore into a clean target database. Apply newer migrations, if any, through the normal migration runner rather than editing restored objects manually.

### 6. Re-provision AI principals

AI login roles/credentials are runtime configuration, not authoritative household facts. Re-run the bounded provisioning scripts:
- local direct-SQL reader, if used;
- curated MCP reader, if used.

Confirm raw-table denial and default read-only transaction mode.

### 7. Bring adapters online internally

Start the internal MCP service with no host port. Verify `/health`, list tools and call one deterministic financial snapshot tool from the internal network.

### 8. Re-enable imports

Re-introduce raw source files through the normal provenance-aware importer. Do not bulk-copy normalized rows around the ingestion contract.

## Credential-loss rule

Provisioning scripts intentionally fail closed if a database login exists but its matching local secret file is missing. Credential rotation after a genuine secret loss is an explicit recovery action; it is never an automatic deployment side effect.

## Synthetic recovery drill

From a clean public clone, run:

```sh
sh scripts/run_synthetic_e2e.sh
```

The script uses an isolated Compose project/container namespace and proves database bootstrap, migrations, fixture/import path, analytics, scenario calculations and MCP queryability without household data.

## What is not backed up to Git

Never use Git as backup storage for:
- PostgreSQL dumps with real rows;
- raw bank/card exports;
- account identifiers;
- runtime DB/MCP passwords;
- private keys or certificates.
