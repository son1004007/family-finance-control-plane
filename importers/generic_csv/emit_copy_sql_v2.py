#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

DEFAULT_NORMALIZER_VERSION = "generic_csv_v2"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def copy_field(value) -> str:
    if value is None:
        return r"\N"
    return (
        str(value)
        .replace("\\", "\\\\")
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
    thousands = spec.get("thousands_separator", ",")
    decimal_sep = spec.get("decimal_separator", ".")
    mode = spec.get("mode", "signed")
    if mode == "signed":
        return parse_money(row.get(require(spec, "column"), ""), thousands, decimal_sep)
    if mode == "debit_credit":
        debit = parse_money(row.get(require(spec, "debit_column"), ""), thousands, decimal_sep)
        credit = parse_money(row.get(require(spec, "credit_column"), ""), thousands, decimal_sep)
        return credit - debit
    raise ValueError(f"unsupported amount.mode: {mode}")


def normalize_timestamp(raw: str, fmt: str, tz_offset: str) -> str:
    dt = datetime.strptime((raw or "").strip(), fmt)
    return dt.isoformat() if dt.tzinfo is not None else dt.strftime("%Y-%m-%dT%H:%M:%S") + tz_offset


def normalize_date(raw: str, fmt: str) -> str | None:
    text = (raw or "").strip()
    return datetime.strptime(text, fmt).date().isoformat() if text else None


def canonical_row_hash(row: dict[str, str]) -> str:
    payload = json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def transaction_hash(row: dict[str, str], columns: list[str]) -> str:
    values = []
    for name in columns:
        if name not in row:
            raise ValueError(f"fingerprint column missing from CSV: {name}")
        values.append((row.get(name) or "").strip())
    return hashlib.sha256(json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def column_value(row: dict[str, str], name: str | None) -> str | None:
    if not name:
        return None
    value = (row.get(name) or "").strip()
    return value or None


def validate_mapping(mapping: dict) -> None:
    if mapping.get("format_version") != 1:
        raise ValueError("only mapping format_version=1 is supported")
    for key in (
        "source_name", "household_label", "account_label", "account_type",
        "institution_type", "institution_label", "currency", "columns",
        "occurred_at_format", "fingerprint_columns"
    ):
        require(mapping, key)
    currency = mapping["currency"]
    if len(currency) != 3 or not currency.isalpha() or not currency.isupper():
        raise ValueError("currency must be an uppercase 3-letter code")
    columns = mapping["columns"]
    require(columns, "occurred_at")
    fingerprints = mapping["fingerprint_columns"]
    if not isinstance(fingerprints, list) or not all(isinstance(x, str) and x for x in fingerprints):
        raise ValueError("fingerprint_columns must be a non-empty list")
    tz = mapping.get("timezone_offset", "+00:00")
    if len(tz) != 6 or tz[0] not in "+-" or tz[3] != ":" or not (tz[1:3] + tz[4:6]).isdigit():
        raise ValueError("timezone_offset must look like +09:00")


def reconciliation_error(mapping: dict, total_rows: int, valid_rows: int, net_amount: Decimal) -> str | None:
    spec = mapping.get("reconciliation") or {}
    problems: list[str] = []
    if "expected_row_count" in spec and int(spec["expected_row_count"]) != total_rows:
        problems.append(f"row_count expected={int(spec['expected_row_count'])} actual={total_rows}")
    if "expected_valid_row_count" in spec and int(spec["expected_valid_row_count"]) != valid_rows:
        problems.append(f"valid_row_count expected={int(spec['expected_valid_row_count'])} actual={valid_rows}")
    if "expected_net_amount" in spec:
        expected = Decimal(str(spec["expected_net_amount"]))
        if expected != net_amount:
            problems.append(f"net_amount expected={expected} actual={net_amount}")
    return "; ".join(problems) if problems else None


def emit(
    csv_path: Path,
    mapping_path: Path,
    file_sha: str,
    mapping_sha: str,
    source_type: str,
    original_filename: str,
    normalizer_version: str,
) -> None:
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
    valid_net = Decimal("0")
    valid_rows = 0
    with csv_path.open("r", encoding=encoding, newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter, quotechar=quotechar)
        if not reader.fieldnames:
            raise ValueError("CSV has no header")
        if len(reader.fieldnames) != len(set(reader.fieldnames)):
            raise ValueError("CSV contains duplicate header names")

        required = list(mapping["fingerprint_columns"]) + [columns["occurred_at"]]
        mode = amount_spec.get("mode", "signed")
        if mode == "signed":
            required.append(require(amount_spec, "column"))
        elif mode == "debit_credit":
            required += [require(amount_spec, "debit_column"), require(amount_spec, "credit_column")]
        else:
            raise ValueError(f"unsupported amount.mode: {mode}")
        missing = sorted(set(required) - set(reader.fieldnames))
        if missing:
            raise ValueError("CSV missing required columns: " + ", ".join(missing))

        for row_number, row in enumerate(reader, start=2):
            payload = json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            row_hash = canonical_row_hash(row)
            tx_hash = occurred_at = booked_on = amount = category = counterparty = description = error = None
            try:
                tx_hash = transaction_hash(row, mapping["fingerprint_columns"])
                occurred_at = normalize_timestamp(row.get(columns["occurred_at"], ""), mapping["occurred_at_format"], timezone_offset)
                if columns.get("booked_on"):
                    booked_on = normalize_date(row.get(columns["booked_on"], ""), booked_format)
                amount_decimal = amount_from_row(row, amount_spec)
                amount = str(amount_decimal)
                valid_net += amount_decimal
                valid_rows += 1
                category = column_value(row, columns.get("category"))
                counterparty = column_value(row, columns.get("counterparty"))
                description = column_value(row, columns.get("description"))
            except Exception as exc:
                error = str(exc)[:1000]
                errors += 1
            rows.append((row_number, row_hash, payload, tx_hash, occurred_at, booked_on, amount, category, counterparty, description, error))

    reconcile_error = reconciliation_error(mapping, len(rows), valid_rows, valid_net)
    source_name = sql_literal(mapping["source_name"])
    household = sql_literal(mapping["household_label"])
    institution_type = sql_literal(mapping["institution_type"])
    institution_label = sql_literal(mapping["institution_label"])
    account_type = sql_literal(mapping["account_type"])
    account_label = sql_literal(mapping["account_label"])
    currency = sql_literal(mapping["currency"])
    normalizer = sql_literal(normalizer_version)
    source_type_sql = sql_literal(source_type)
    batch_where = (
        f"source_type={source_type_sql} AND source_name={source_name} "
        f"AND file_sha256='{file_sha}' AND mapping_sha256='{mapping_sha}'"
    )

    print("BEGIN;")
    print("CREATE TEMP TABLE generic_stage(row_number integer, raw_hash char(64), raw_payload jsonb, tx_hash char(64), occurred_at timestamptz, booked_on date, amount numeric(20,2), category text, counterparty text, description text, normalization_error text) ON COMMIT DROP;")
    print("COPY generic_stage(row_number,raw_hash,raw_payload,tx_hash,occurred_at,booked_on,amount,category,counterparty,description,normalization_error) FROM STDIN WITH (FORMAT text);")
    for row in rows:
        print("\t".join(copy_field(value) for value in row))
    print(r"\.")
    print(f"INSERT INTO finance.households(label,base_currency) VALUES ({household},{currency}) ON CONFLICT(label) DO NOTHING;")
    print(f"INSERT INTO finance.institutions(institution_type,display_label) VALUES ({institution_type},{institution_label}) ON CONFLICT(institution_type,display_label) DO NOTHING;")
    print("INSERT INTO finance.accounts(household_id,institution_id,account_type,account_label,currency) "
          f"SELECT h.household_id,i.institution_id,{account_type},{account_label},{currency} FROM finance.households h CROSS JOIN finance.institutions i "
          f"WHERE h.label={household} AND i.institution_type={institution_type} AND i.display_label={institution_label} ON CONFLICT(household_id,account_label) DO NOTHING;")
    final_status = "failed" if reconcile_error else ("partial" if errors else "completed")
    final_errors = errors + (1 if reconcile_error else 0)
    print("INSERT INTO ingest.import_batches(source_type,source_name,original_filename,file_sha256,mapping_sha256,normalizer_version,status,row_count,error_count,completed_at) "
          f"VALUES ({source_type_sql},{source_name},{sql_literal(original_filename)},'{file_sha}','{mapping_sha}',{normalizer},'started',0,0,NULL) ON CONFLICT DO NOTHING;")
    print("INSERT INTO ingest.source_rows(import_batch_id,source_row_number,source_row_hash,raw_payload,normalized,normalization_error) "
          "SELECT b.import_batch_id,s.row_number,s.raw_hash,s.raw_payload,(s.normalization_error IS NULL),s.normalization_error FROM generic_stage s CROSS JOIN ingest.import_batches b "
          f"WHERE {batch_where} ON CONFLICT DO NOTHING;")
    if not reconcile_error:
        print("INSERT INTO finance.transactions(account_id,occurred_at,booked_on,amount,currency,category,counterparty,description,source_row_hash,import_batch_id) "
              f"SELECT a.account_id,s.occurred_at,s.booked_on,s.amount,{currency},s.category,s.counterparty,s.description,s.tx_hash,b.import_batch_id FROM generic_stage s "
              f"JOIN finance.households h ON h.label={household} JOIN finance.accounts a ON a.household_id=h.household_id AND a.account_label={account_label} CROSS JOIN ingest.import_batches b "
              f"WHERE {batch_where} AND s.normalization_error IS NULL ON CONFLICT (account_id,source_row_hash) WHERE source_row_hash IS NOT NULL "
              "DO UPDATE SET occurred_at=EXCLUDED.occurred_at,booked_on=EXCLUDED.booked_on,amount=EXCLUDED.amount,currency=EXCLUDED.currency,category=EXCLUDED.category,counterparty=EXCLUDED.counterparty,description=EXCLUDED.description,import_batch_id=EXCLUDED.import_batch_id;")
    print(f"UPDATE ingest.import_batches SET status='{final_status}',row_count={len(rows)},error_count={final_errors},completed_at=now() WHERE {batch_where};")
    print("COMMIT;")
    marker = "FAIL" if reconcile_error else "PASS"
    detail = (reconcile_error or "").replace("'", "''")
    print("SELECT 'IMPORT_BATCH=" + marker + " source=' || source_name || ' rows=' || row_count || ' errors=' || error_count || ' status=' || status || " + sql_literal((" reconciliation=" + detail) if detail else "") + f" FROM ingest.import_batches WHERE {batch_where};")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv")
    parser.add_argument("mapping")
    parser.add_argument("file_sha256")
    parser.add_argument("mapping_sha256")
    parser.add_argument("--source-type", default="generic_csv")
    parser.add_argument("--original-filename")
    parser.add_argument("--normalizer-version", default=DEFAULT_NORMALIZER_VERSION)
    args = parser.parse_args()
    for value in (args.file_sha256, args.mapping_sha256):
        if len(value) != 64 or any(ch not in "0123456789abcdefABCDEF" for ch in value):
            raise SystemExit("sha256 arguments must be 64 hex characters")
    if not args.source_type.replace("_", "").isalnum():
        raise SystemExit("source type must contain only letters, numbers, underscore")
    emit(
        Path(args.csv), Path(args.mapping), args.file_sha256, args.mapping_sha256,
        args.source_type, args.original_filename or Path(args.csv).name, args.normalizer_version,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
