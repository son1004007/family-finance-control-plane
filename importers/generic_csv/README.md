# Generic CSV transaction importer

This importer is the first Stage 5 ingestion path. It is intentionally institution-neutral and requires an explicit JSON mapping rather than guessing bank columns.

## Data boundary

Real exports stay outside Git. A normal runtime layout is:

```text
/data/family-finance/raw/<institution>/transactions.csv
/data/family-finance/mappings/<institution>.json
```

Only synthetic CSV files may be committed to this public repository.

## Run

From the deployed repository on a Docker host:

```sh
sh scripts/import_generic_csv.sh /path/to/transactions.csv /path/to/mapping.json
```

The host does not need Python packages. Normalization runs in a disposable `python:3.12-alpine` container and the resulting COPY stream is applied to the private PostgreSQL container.

## Mapping format

See `tests/fixtures/synthetic/generic_bank_mapping.json` for a complete example.

Required concepts:

- `source_name`: stable name for this export source.
- `household_label`: target household.
- `institution_type` / `institution_label`.
- `account_type` / `account_label`.
- `currency`.
- `columns.occurred_at` and `occurred_at_format`.
- `amount`: either `signed` or `debit_credit` mode.
- `fingerprint_columns`: raw source columns that identify the same transaction across overlapping exports.

### Fingerprint rule

Prefer a bank-provided transaction/reference ID. If the export does not provide one, define a conservative combination of raw columns such as date/time, amount, description and post-transaction balance. A weak fingerprint can collapse two legitimate identical transactions; an unstable fingerprint can create duplicates.

The transaction fingerprint is derived from raw source fields, not normalized values. This lets a corrected mapping update a previously imported transaction instead of creating a second transaction.

## Provenance and idempotency

Each import records:

- source file SHA-256,
- mapping SHA-256,
- normalizer version,
- raw row JSON,
- raw row SHA-256,
- normalization status/error.

Re-running the same completed file with the same mapping returns `IMPORT_ALREADY_APPLIED=PASS` without creating duplicate rows. A mapping change creates a new import batch; stable transaction fingerprints allow normalized transaction fields to be corrected in place.

## Error behavior

Malformed rows are not silently discarded. They are retained in `ingest.source_rows` with `normalized=false` and `normalization_error`, while valid rows are loaded into `finance.transactions`. The batch status becomes `partial` when one or more rows fail normalization.

Institution-specific mappings should be added only after examining an actual export format. Do not infer private institution formats in public code.
