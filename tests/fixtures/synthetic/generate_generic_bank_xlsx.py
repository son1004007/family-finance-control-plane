#!/usr/bin/env python3
from __future__ import annotations

import csv
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape


def col_name(index: int) -> str:
    value = index + 1
    chars = []
    while value:
        value, rem = divmod(value - 1, 26)
        chars.append(chr(65 + rem))
    return "".join(reversed(chars))


def inline_cell(ref: str, value: str) -> str:
    return f'<c r="{ref}" t="inlineStr"><is><t>{escape(value)}</t></is></c>'


def write_xlsx(csv_path: Path, out_path: Path) -> None:
    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle))
    sheet_rows = []
    for row_no, row in enumerate(rows, start=1):
        cells = "".join(inline_cell(f"{col_name(i)}{row_no}", value) for i, value in enumerate(row))
        sheet_rows.append(f'<row r="{row_no}">{cells}</row>')
    worksheet = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>' + "".join(sheet_rows) + '</sheetData></worksheet>'
    )
    content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>'''
    root_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>'''
    workbook = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Transactions" sheetId="1" r:id="rId1"/></sheets>
</workbook>'''
    workbook_rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>'''
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", root_rels)
        zf.writestr("xl/workbook.xml", workbook)
        zf.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        zf.writestr("xl/worksheets/sheet1.xml", worksheet)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_generic_bank_xlsx.py <input.csv> <output.xlsx>")
    write_xlsx(Path(sys.argv[1]), Path(sys.argv[2]))
