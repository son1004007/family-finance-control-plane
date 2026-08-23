#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

NORMALIZER_VERSION = "generic_csv_v1"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def copy_field(value) -> str:
    if value is None:
        return r"\N"
    text = str(value)
    return (
        text.replace("\\", "\\\\")
        .replace("\t", r"\t")
        .replace("\n", r"\n")
        .replace("\r", r"\r")
    )


def require(mapping: dict, key: str):
    value = mapping.get(key)
    if value in (None, "", []):
        raise ValueError(f"mapping requires {key}")
    return value


def parse_money(raw: str, thousands: str, decimal_sep: str) -> Decimal:
    text = (raw or "").strip()
    if not text:
        return Decimal("0")
    if thousands:
        text = text.replace(thousands, "")
    if decimal_sep and decimal_sep != ".":
        text = text.replace(decimal_sep, ".")
    try:
        return Decimal(text)
    except InvalidOperation as exc:
        raise ValueError(f"invalid money value: {raw!r}") from exc


def amount_from_row(row: dict[str, str], spec: dict) -> Decimal:
    mode = spec.get("mode", "signed")
    thousands = spec.get("thousands_separator", ",")
    decimal_sep = spec.get("decimal_separator", ".")
    if mode == "signed":
        column = require(spec, "column")
        return parse_money(row.get(column, ""), thousands, decimal_sep)
    if mode == "debit_credit":
        debit = parse_money(
            row.get(require(spec, "debit_column"), ""), thousands, decimal_sep
        )
        credit = parse_money(
            row.get(require(spec, "credit_column"), ""), thousands, decimal_sep
        )
        return credit - debit
    raise ValueError(f"unsupported amount.mode: {mode}")


def normalize_timestamp(raw: str, fmt: str, tz_offset: str) -> str:
    dt = datetime.strptime((raw or "").strip(), fmt)
    if dt.tzinfo is not None:
        return dt.isoformat()
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + tz_offset


def normalize_date(raw: str, fmt: str) -> str | None:
    text = (raw or "").strip()
    if not text:
        return None
    return datetime.strptime(text, fmt).date().isoformat()


def raw_hash(row: dict[str, str]) -> str:
    payload = json.dumps(
        row, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def transaction_hash(row: dict[str, str], columns: list[str]) -> str:
    values = []
    for name in columns:
        if name not in row:
            raise ValueError(f"fingerprint column missing from CSV: {name}")
        values.append((row.get(name) or "").strip())
    payload = json.dumps(values, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def column_value(row: dict[str, str], name: str | None) -> str | None:
    if not name:
        return None
    value = (row.get(name) or "").strip()
    return value or None


def validate_mapping(mapping: dict) -> None:
    if mapping.get("format_version") != 1:
        raise ValueError("only mapping format_version=1 is supported")
    require(mapping, "source_name")
    require(mapping, "household_label")
    require(mapping, "account_label")
    require(mapping, "account_type")
    require(mapping, "institution_type")
    require(mapping, "institution_label")
    currency = require(mapping, "currency")
    if len(currency) != 3 or not currency.isalpha() or not currency.isupper():
        raise ValueError("currency must be an uppercase ISO-style 3-letter code")
    columns = require(mapping, "columns")
    require(columns, "occurred_at")
    require(mapping, "occurred_at_format")
    fingerprints = require(mapping, "fingerprint_columns")
    if not isinstance(fingerprints, list) or not all(
        isinstance(value, str) and value for value in fingerprints
    ):
        raise ValueError(
            "fingerprint_columns must be a non-empty list of column names"
        )
    tz_offset = mapping.get("timezone_offset", "+00:00")
    if (
        len(tz_offset) != 6
        or tz_offset[0] not in "+-"
        or tz_offset[3] != ":"
        or not (tz_offset[1:3] + tz_offset[4:6]).isdigit()
    ):
        raise ValueError("timezone_offset must look like +09:00")


def emit(csv_path: Path, mapping_path: Path, file_sha: str, mapping_sha: str) -> None:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    validate_mapping(mapping)
    columns = mapping["columns"]
    encoding = mapping.get("encoding", "utf-8-sig")
    delimiter = mapping.get("delimiter", ",")
    quotechar = mapping.get("quotechar", '"')
    timezone_offset = mapping.get("timezone_offset", "+00:00")
    booked_format = mapping.get("booked_on_format", "%Y-%m-%d")
    amount_spec = mapping.get("amount", {})

    rows = []
    errors = 0
    with csv_path.open("r", encoding=encoding, newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter, quotechar=quotechar)
        if not reader.fieldnames:
            raise ValueError("CSV has no header")

        required_csv = list(mapping["fingerprint_columns"])
        required_csv.append(columns["occurred_at"])
        if amount_spec.get("mode", "signed") == "signed":
            required_csv.append(require(amount_spec, "column"))
        elif amount_spec.get("mode") == "debit_credit":
            required_csv.extend(
                [
                    require(amount_spec, "debit_column"),
                    require(amount_spec, "credit_column"),
                ]
            )
        else:
            raise ValueError(f"unsupported amount.mode: {amount_spec.get('mode')}")
        missing = sorted(set(required_csv) - set(reader.fieldnames))
        if missing:
            raise ValueError("CSV missing required columns: " + ", ".join(missing))

        for row_number, row in enumerate(reader, start=2):
            payload = json.dumps(
                row, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
            row_hash = raw_hash(row)
            tx_hash = None
            occurred_at = None
            booked_on = None
            amount = None
            category = None
            counterparty = None
            description = None
            error = None
            try:
                tx_hash = transaction_hash(row, mapping["fingerprint_columns"])
                occurred_at = normalize_timestamp(
                    row.get(columns["occurred_at"], ""),
                    mapping["occurred_at_format"],
                    timezone_offset,
                )
                if columns.get("booked_on"):
                    booked_on = normalize_date(
                        row.get(columns["booked_on"], ""), booked_format
                    )
                amount = str(amount_from_row(row, amount_spec))
                category = column_value(row, columns.get("category"))
                counterparty = column_value(row, columns.get("counterparty"))
                description = column_value(row, columns.get("description"))
            except Exception as exc:  # preserve malformed source rows for review
                error = str(exc)[:1000]
                errors += 1
            rows.append(
                (
                    row_number,
                    row_hash,
                    payload,
                    tx_hash,
                    occurred_at,
                    booked_on,
                    amount,
                    category,
                    counterparty,
                    description,
                    error,
                )
            )

    source_name = sql_literal(mapping["source_name"])
    household = sql_literal(mapping["household_label"])
    institution_type = sql_literal(mapping["institution_type"])
    institution_label = sql_literal(mapping["institution_label"])
    account_type = sql_literal(mapping["account_type"])
    account_label = sql_literal(mapping["account_label"])
    currency = sql_literal(mapping["currency"])
    normalizer = sql_literal(NORMALIZER_VERSION)
    batch_where = (
        "source_type='generic_csv' "
        f"AND source_name={source_name} "
        f"AND file_sha256='{file_sha}' "
        f"AND mapping_sha256='{mapping_sha}'"
    )

    print("BEGIN;")
    print(
        "CREATE TEMP TABLE generic_csv_stage("
        "row_number integer, raw_hash char(64), raw_payload jsonb, "
        "tx_hash char(64), occurred_at timestamptz, booked_on date, "
        "amount numeric(20,2), category text, counterparty text, "
        "description text, normalization_error text) ON COMMIT DROP;"
    )
    print(
        "COPY generic_csv_stage("
        "row_number,raw_hash,raw_payload,tx_hash,occurred_at,booked_on,"
        "amount,category,counterparty,description,normalization_error) "
        "FROM STDIN WITH (FORMAT text);"
    )
    for row in rows:
        print("\t".join(copy_field(value) for value in row))
    print(r"\.")

    print(
        f"INSERT INTO finance.households(label,base_currency) "
        f"VALUES ({household},{currency}) ON CONFLICT(label) DO NOTHING;"
    )
    print(
        "INSERT INTO finance.institutions(institution_type,display_label) "
        f"VALUES ({institution_type},{institution_label}) "
        "ON CONFLICT(institution_type,display_label) DO NOTHING;"
    )
    print(
        "INSERT INTO finance.accounts("
        "household_id,institution_id,account_type,account_label,currency) "
        f"SELECT h.household_id,i.institution_id,{account_type},{account_label},{currency} "
        "FROM finance.households h CROSS JOIN finance.institutions i "
        f"WHERE h.label={household} AND i.institution_type={institution_type} "
        f"AND i.display_label={institution_label} "
        "ON CONFLICT(household_id,account_label) DO NOTHING;"
    )
    print(
        "INSERT INTO ingest.import_batches("
        "source_type,source_name,original_filename,file_sha256,mapping_sha256,"
        "normalizer_version,status,row_count,error_count,completed_at) "
        f"VALUES ('generic_csv',{source_name},{sql_literal(csv_path.name)},"
        f"'{file_sha}','{mapping_sha}',{normalizer},'started',0,0,NULL) "
        "ON CONFLICT DO NOTHING;"
    )
    print(
        "INSERT INTO ingest.source_rows("
        "import_batch_id,source_row_number,source_row_hash,raw_payload,"
        "normalized,normalization_error) "
        "SELECT b.import_batch_id,s.row_number,s.raw_hash,s.raw_payload,"
        "(s.normalization_error IS NULL),s.normalization_error "
        "FROM generic_csv_stage s CROSS JOIN ingest.import_batches b "
        f"WHERE {batch_where} ON CONFLICT DO NOTHING;"
    )
    print(
        "INSERT INTO finance.transactions("
        "account_id,occurred_at,booked_on,amount,currency,category,counterparty,"
        "description,source_row_hash,import_batch_id) "
        "SELECT a.account_id,s.occurred_at,s.booked_on,s.amount,"
        f"{currency},s.category,s.counterparty,s.description,s.tx_hash,b.import_batch_id "
        "FROM generic_csv_stage s "
        f"JOIN finance.households h ON h.label={household} "
        "JOIN finance.accounts a ON a.household_id=h.household_id "
        f"AND a.account_label={account_label} "
        "CROSS JOIN ingest.import_batches b "
        f"WHERE {batch_where} AND s.normalization_error IS NULL "
        "ON CONFLICT (account_id,source_row_hash) WHERE source_row_hash IS NOT NULL "
        "DO UPDATE SET occurred_at=EXCLUDED.occurred_at,"
        "booked_on=EXCLUDED.booked_on,amount=EXCLUDED.amount,"
        "currency=EXCLUDED.currency,category=EXCLUDED.category,"
        "counterparty=EXCLUDED.counterparty,description=EXCLUDED.description,"
        "import_batch_id=EXCLUDED.import_batch_id;"
    )
    status = "partial" if errors else "completed"
    print(
        "UPDATE ingest.import_batches "
        f"SET status='{status}',row_count={len(rows)},error_count={errors},completed_at=now() "
        f"WHERE {batch_where};"
    )
    print("COMMIT;")
    print(
        "SELECT 'IMPORT_BATCH=PASS source=' || source_name || "
        "' rows=' || row_count || ' errors=' || error_count || ' status=' || status "
        f"FROM ingest.import_batches WHERE {batch_where};"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    parser.add_argument("mapping")
    parser.add_argument("file_sha256")
    parser.add_argument("mapping_sha256")
    args = parser.parse_args()
    for value in (args.file_sha256, args.mapping_sha256):
        if len(value) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in value):
            raise SystemExit("sha256 arguments must be 64 hex characters")
    emit(Path(args.csv), Path(args.mapping), args.file_sha256, args.mapping_sha256)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
