# Generic CSV runtime guide

Use the generic importer only after the database migrations have been applied.

```sh
sh scripts/import_generic_csv.sh /private/path/transactions.csv /private/path/mapping.json
```

Operational rules:

- keep real exports and real mappings outside the public repository;
- prefer a stable source-provided transaction ID in `fingerprint_columns`;
- inspect `ingest.source_rows` when a batch is `partial`;
- reconcile source statement totals before treating imported data as authoritative;
- do not delete a failed/partial batch merely to hide errors;
- if a mapping changes, re-import with the corrected mapping and verify canonical transaction counts and totals.

The importer deliberately uses a disposable Python container so Synology or other Docker hosts do not require host Python dependencies.
