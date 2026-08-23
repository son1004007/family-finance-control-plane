# 04. Generic import and deterministic analytics

Stage 4 real household input can be deferred without blocking reusable implementation work.

This phase adds two independent capabilities using synthetic data only:

1. a generic CSV transaction import path with explicit mapping and provenance;
2. deterministic SQL metrics shared by every AI client.

## Import design

The generic importer never guesses column meanings. A mapping file declares the account, currency, timestamp format, amount representation and stable raw transaction fingerprint columns.

For every import the system stores the source-file SHA-256, mapping SHA-256, normalizer version, raw row JSON, raw row hash and normalization errors. Valid rows become canonical transactions. Malformed rows remain visible in the ingest layer instead of disappearing silently.

A transaction fingerprint is derived from selected raw source fields. This is important for overlapping exports: re-importing the same source does not create a second canonical transaction, and a corrected mapping can update normalized fields when the raw source identity remains stable.

## Analytics design

Important arithmetic belongs in PostgreSQL rather than in an LLM prompt. The current deterministic layer includes:

- monthly spending by category;
- liquid reserve by currency;
- calendar-complete monthly cash flow;
- rolling 3/6/12-month cash flow;
- current income gap against a versioned planning benchmark;
- a household financial snapshot combining income, fixed obligations, net worth and liquidity.

Currencies are never implicitly mixed. Cross-currency totals require a future dated FX layer.

## Privacy boundary

Only synthetic export fixtures are committed publicly. Real CSV/XLSX exports and institution-specific private mappings stay in the runtime data boundary.

## Validation

CI uses a fictional transaction export containing both valid and malformed rows. It imports the file twice and verifies:

- one import provenance batch for the same file+mapping;
- all raw rows remain traceable;
- malformed rows are counted as errors;
- only valid rows become transactions;
- the second import does not create duplicate transactions;
- deterministic metric views return the expected fictional values.
