# 07. Reproducibility, Retention and Recovery

A finance system is not trustworthy because one deployment worked once. It should be rebuildable and its backups should be restorable.

## One-command synthetic path

The public repository includes:

```sh
sh scripts/run_synthetic_e2e.sh
```

It creates an isolated Compose project, then executes the complete fictional path:

```text
PostgreSQL
 -> migrations
 -> synthetic factual/scenario snapshots
 -> CSV import
 -> XLSX import
 -> deterministic analytics assertions
 -> narrow MCP login
 -> internal MCP server
 -> actual MCP tool calls
```

The project/container names are deliberately different from the normal runtime names so this drill cannot accidentally reset the live stack.

## Import provenance and reconciliation

CSV and XLSX imports share one normalization/provenance path. The recorded fingerprint belongs to the original source file, not a temporary converted file.

Optional reconciliation expectations can verify row counts and net amount. If reconciliation fails, source provenance is retained but transaction writes are blocked.

## Backups

Each logical PostgreSQL backup is restored into a temporary database before it is accepted. The verification checks migration and major finance-table row counts. Only after this passes can old backups be pruned by the configured keep count.

## Retention

Source archive/rejected cleanup is dry-run by default. Applying deletion requires an explicit environment switch. Candidate reporting contains counts rather than private filenames/content.

## Why the public fixture matters

A fictional full path gives contributors and automated agents a known target without needing the owner's data. If the synthetic build cannot reproduce its exact results, the system should not be trusted with a real household baseline.
