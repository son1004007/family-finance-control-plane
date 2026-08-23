#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import zipfile
from datetime import datetime, timedelta
from pathlib import Path
from xml.etree import ElementTree as ET

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
CELL_REF = re.compile(r"^([A-Z]+)([0-9]+)$")


def col_index(cell_ref: str) -> int:
    match = CELL_REF.match(cell_ref)
    if not match:
        raise ValueError(f"invalid XLSX cell reference: {cell_ref}")
    value = 0
    for ch in match.group(1):
        value = value * 26 + (ord(ch) - 64)
    return value - 1


def shared_strings(zf: zipfile.ZipFile) -> list[str]:
    try:
        root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
    except KeyError:
        return []
    values = []
    for si in root.findall(f"{{{NS_MAIN}}}si"):
        values.append("".join(node.text or "" for node in si.iter(f"{{{NS_MAIN}}}t")))
    return values


def worksheet_path(zf: zipfile.ZipFile, requested: str | None) -> str:
    workbook = ET.fromstring(zf.read("xl/workbook.xml"))
    sheets = workbook.find(f"{{{NS_MAIN}}}sheets")
    if sheets is None:
        raise ValueError("XLSX workbook has no sheets")
    selected = next((sheet for sheet in list(sheets) if requested is None or sheet.attrib.get("name") == requested), None)
    if selected is None:
        raise ValueError(f"XLSX sheet not found: {requested}")
    rel_id = selected.attrib.get(f"{{{NS_REL}}}id")
    rels = ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))
    target = next((rel.attrib.get("Target") for rel in rels.findall(f"{{{NS_PKG}}}Relationship") if rel.attrib.get("Id") == rel_id), None)
    if not target:
        raise ValueError("XLSX worksheet relationship is missing")
    target = target.lstrip("/")
    return target if target.startswith("xl/") else "xl/" + target


def cell_text(cell: ET.Element, strings: list[str]) -> str:
    cell_type = cell.attrib.get("t")
    if cell_type == "inlineStr":
        inline = cell.find(f"{{{NS_MAIN}}}is")
        return "" if inline is None else "".join(node.text or "" for node in inline.iter(f"{{{NS_MAIN}}}t"))
    value = cell.find(f"{{{NS_MAIN}}}v")
    raw = "" if value is None or value.text is None else value.text
    if cell_type == "s" and raw:
        return strings[int(raw)]
    if cell_type == "b":
        return "TRUE" if raw == "1" else "FALSE"
    return raw


def excel_serial_to_iso(raw: str, include_time: bool) -> str:
    dt = datetime(1899, 12, 30) + timedelta(days=float(raw))
    return dt.strftime("%Y-%m-%dT%H:%M:%S" if include_time else "%Y-%m-%d")


def convert(xlsx_path: Path, mapping_path: Path, output_path: Path) -> None:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    xlsx = mapping.get("xlsx") or {}
    sheet_name = xlsx.get("sheet")
    header_row = int(xlsx.get("header_row", 1))
    if header_row < 1:
        raise ValueError("xlsx.header_row must be >= 1")
    excel_date_columns = set(xlsx.get("excel_date_columns") or [])
    excel_datetime_columns = set(xlsx.get("excel_datetime_columns") or [])
    delimiter = mapping.get("delimiter", ",")
    quotechar = mapping.get("quotechar", '"')
    if len(delimiter) != 1 or len(quotechar) != 1:
        raise ValueError("delimiter and quotechar must be one character")

    with zipfile.ZipFile(xlsx_path) as zf:
        strings = shared_strings(zf)
        root = ET.fromstring(zf.read(worksheet_path(zf, sheet_name)))
        sheet_data = root.find(f"{{{NS_MAIN}}}sheetData")
        if sheet_data is None:
            raise ValueError("XLSX worksheet has no sheetData")
        rows: dict[int, dict[int, str]] = {}
        max_col = -1
        for row in sheet_data.findall(f"{{{NS_MAIN}}}row"):
            row_no = int(row.attrib.get("r", "0"))
            cells: dict[int, str] = {}
            for cell in row.findall(f"{{{NS_MAIN}}}c"):
                idx = col_index(cell.attrib.get("r", ""))
                cells[idx] = cell_text(cell, strings)
                max_col = max(max_col, idx)
            rows[row_no] = cells

    if header_row not in rows:
        raise ValueError(f"XLSX header row {header_row} is missing")
    header_cells = rows[header_row]
    width = max(max_col + 1, max(header_cells.keys(), default=-1) + 1)
    headers = [header_cells.get(i, "").strip() for i in range(width)]
    while headers and not headers[-1]:
        headers.pop()
    if not headers or any(not value for value in headers):
        raise ValueError("XLSX header contains blank columns")
    if len(headers) != len(set(headers)):
        raise ValueError("XLSX header contains duplicate names")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter=delimiter, quotechar=quotechar)
        writer.writerow(headers)
        for row_no in sorted(number for number in rows if number > header_row):
            values = [rows[row_no].get(i, "") for i in range(len(headers))]
            if not any(value.strip() for value in values):
                continue
            for idx, header in enumerate(headers):
                if values[idx] and header in excel_date_columns:
                    values[idx] = excel_serial_to_iso(values[idx], False)
                elif values[idx] and header in excel_datetime_columns:
                    values[idx] = excel_serial_to_iso(values[idx], True)
            writer.writerow(values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("xlsx")
    parser.add_argument("mapping")
    parser.add_argument("output_csv")
    args = parser.parse_args()
    convert(Path(args.xlsx), Path(args.mapping), Path(args.output_csv))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
