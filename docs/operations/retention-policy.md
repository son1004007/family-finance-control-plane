# Retention Policy

Retention is a privacy and recoverability control. It must not become an unattended data-loss mechanism.

## PostgreSQL backups

The backup script retains the newest `BACKUP_KEEP` verified dumps, default **14**. Pruning occurs only after the newly created dump has passed isolated restore verification.

This is count-based rather than age-based so an idle system still retains a minimum recent recovery set.

## Imported source lifecycle

The drop-folder importer separates files into:

```text
imports/
  raw/       # waiting to be processed
  mappings/  # mapping definitions
  archive/   # successfully handled source files
  rejected/  # missing mapping or failed import/reconciliation
```

Default cleanup windows:
- archive: 180 days
- rejected: 90 days

These are reference defaults, not legal retention advice.

## Dry-run first

`scripts/retention_cleanup.sh` never deletes by default.

```sh
FINANCE_IMPORT_ROOT=/path/to/imports sh scripts/retention_cleanup.sh
```

It reports only candidate counts, not filenames or financial contents.

Deletion requires an explicit flag:

```sh
FINANCE_IMPORT_ROOT=/path/to/imports \
RETENTION_APPLY=1 \
sh scripts/retention_cleanup.sh
```

The script rejects retention periods shorter than seven days and only removes regular files older than the configured age plus empty child directories.

## Raw source preservation

Raw exports are DATA-ONLY. They may be needed to reproduce normalization or recover after database loss. Before shortening archive retention, confirm that database backup history and institution re-export capability are sufficient.

## Rejected imports

Rejected files should not be silently retried indefinitely. Investigate mapping/reconciliation failures, correct the mapping or source, then reintroduce the source through `raw/` as a normal import.

## Scheduling

The public project intentionally does not create a NAS/system scheduler entry. A scheduler is an environment-specific operational write. If enabled later, use two tasks:

1. periodic verified PostgreSQL backup;
2. retention dry-run, reviewed before converting to apply mode.

Do not combine deletion with an unverified backup job.
