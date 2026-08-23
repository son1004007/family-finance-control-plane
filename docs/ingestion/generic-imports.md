# Generic CSV and XLSX Imports

The importer is mapping-driven so institution-specific formats do not require hard-coded household data.

## Mapping contract

A mapping identifies:
- source name;
- synthetic/private household label at runtime;
- institution/account labels and types;
- currency;
- source column names;
- timestamp/date formats;
- signed or debit/credit amount parsing;
- deterministic fingerprint columns;
- optional reconciliation expectations.

Use `tests/fixtures/synthetic/generic_bank_mapping.json` and `generic_bank_xlsx_mapping.json` as fictional examples.

## CSV

```sh
sh scripts/import_generic_csv.sh transactions.csv mapping.json
```

The importer computes the original file SHA-256 and mapping SHA-256, records source-row provenance, normalizes valid rows and deduplicates transactions by account + deterministic source fingerprint.

## XLSX

```sh
sh scripts/import_generic_xlsx.sh transactions.xlsx mapping.json
```

The XLSX path uses a standard-library OOXML converter in a disposable Python container. It does not require Excel, LibreOffice, pandas or openpyxl on the host.

Supported workbook controls:

```json
{
  "xlsx": {
    "sheet": "Transactions",
    "header_row": 1,
    "excel_date_columns": [],
    "excel_datetime_columns": []
  }
}
```

The source fingerprint stored in PostgreSQL is the **original XLSX SHA**, not the temporary converted CSV SHA.

## Reconciliation

Optional mapping fields:

```json
{
  "reconciliation": {
    "expected_row_count": 10,
    "expected_valid_row_count": 10,
    "expected_net_amount": 12345
  }
}
```

If a declared expectation does not match:
- import batch becomes `failed`;
- raw/source-row provenance is retained;
- normalized transaction writes are blocked;
- the command exits non-zero.

This prevents a partially interpreted export from silently becoming financial truth.

## Drop folder

Default structure:

```text
.local/imports/
  raw/
  mappings/
  archive/
  rejected/
```

Set a private runtime root with `FINANCE_IMPORT_ROOT` and run:

```sh
FINANCE_IMPORT_ROOT=/private/import/root sh scripts/import_drop_folder.sh
```

Mapping lookup order for a file such as `statement.xlsx`:
1. `mappings/statement.xlsx.mapping.json`
2. `mappings/statement.mapping.json`
3. `mappings/default.xlsx.mapping.json`

Successful files move to a dated archive directory. Missing mappings or failed imports move to `rejected/`. The command reports counts, not source filenames or contents.

## Real exports

Raw household exports are DATA-ONLY and must stay outside Git. If an institution format cannot be inferred from an existing mapping, use one representative export to create a new mapping, validate it locally, and retain the export only inside the private data boundary.
