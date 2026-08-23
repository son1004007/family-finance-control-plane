#!/usr/bin/env python3
"""Fail CI when public-repository content crosses the private-data boundary.

This scanner complements GitHub secret scanning/Gitleaks. It focuses on project-specific
risks such as raw financial exports and exact household terms supplied through a CI secret.
It intentionally never prints the denylisted value itself.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()

ALLOWED_ENV_NAMES = {".env.example", ".env.sample", ".env.template"}
BLOCKED_FILE_SUFFIXES = {
    ".sqlite",
    ".sqlite3",
    ".db",
    ".dump",
    ".backup",
    ".p12",
    ".pfx",
    ".key",
    ".jks",
    ".keystore",
    ".ofx",
    ".qif",
}
FINANCIAL_EXPORT_SUFFIXES = {".csv", ".xls", ".xlsx"}
ALLOWED_SYNTHETIC_PREFIXES = (
    "examples/synthetic/",
    "fixtures/synthetic/",
    "tests/fixtures/synthetic/",
)
BLOCKED_TOP_LEVEL_DIRS = {"private-data", "raw-data", "secrets", "backups"}
SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "dist", "build", "__pycache__"}
MAX_TEXT_BYTES = 2 * 1024 * 1024

# Korean resident registration number shape. This is treated as private even if validation
# of the check digit is not attempted.
RRN_PATTERN = re.compile(r"(?<!\d)\d{6}-?[1-4]\d{6}(?!\d)")
PRIVATE_KEY_PATTERN = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")


def relative(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def is_synthetic_export(rel: str) -> bool:
    return rel.startswith(ALLOWED_SYNTHETIC_PREFIXES)


def denylist_terms() -> list[str]:
    raw = os.environ.get("PUBLIC_BOUNDARY_DENYLIST", "")
    return [line.strip() for line in raw.splitlines() if line.strip()]


def term_fingerprint(term: str) -> str:
    return hashlib.sha256(term.encode("utf-8")).hexdigest()[:12]


def path_violations(path: Path) -> list[str]:
    rel = relative(path)
    parts = Path(rel).parts
    name = path.name.lower()
    suffix = path.suffix.lower()
    violations: list[str] = []

    if parts and parts[0].lower() in BLOCKED_TOP_LEVEL_DIRS:
        violations.append("blocked top-level private/raw/backup directory")

    if name.startswith(".env") and name not in ALLOWED_ENV_NAMES:
        violations.append("environment file is not allowed in public Git")

    if suffix in BLOCKED_FILE_SUFFIXES:
        violations.append(f"blocked sensitive file type: {suffix}")

    if suffix in FINANCIAL_EXPORT_SUFFIXES and not is_synthetic_export(rel):
        violations.append(
            "financial export file is allowed only under an explicit synthetic fixture path"
        )

    return violations


def read_text(path: Path) -> str | None:
    try:
        if path.stat().st_size > MAX_TEXT_BYTES:
            return None
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def content_violations(path: Path, terms: list[str]) -> list[str]:
    text = read_text(path)
    if text is None:
        return []

    violations: list[str] = []
    if RRN_PATTERN.search(text):
        violations.append("possible Korean resident-registration number")
    if PRIVATE_KEY_PATTERN.search(text):
        violations.append("private-key material")

    for term in terms:
        if term in text:
            violations.append(
                "private denylist match fingerprint=" + term_fingerprint(term)
            )
    return violations


def iter_files(root: Path):
    for current_root, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        current = Path(current_root)
        for filename in filenames:
            yield current / filename


def scan(root: Path | None = None, terms: list[str] | None = None) -> list[tuple[str, str]]:
    global ROOT
    if root is not None:
        ROOT = root.resolve()
    terms = denylist_terms() if terms is None else terms

    findings: list[tuple[str, str]] = []
    for path in iter_files(ROOT):
        rel = relative(path)
        for reason in path_violations(path):
            findings.append((rel, reason))
        for reason in content_violations(path, terms):
            findings.append((rel, reason))
    return findings


def main() -> int:
    findings = scan()
    if not findings:
        print("Public boundary scan: PASS")
        return 0

    print("Public boundary scan: FAIL", file=sys.stderr)
    for rel, reason in findings:
        print(f"- {rel}: {reason}", file=sys.stderr)
    print(
        "Remove/sanitize the content or move private financial data outside the public repository.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
