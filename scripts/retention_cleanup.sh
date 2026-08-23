#!/usr/bin/env sh
set -eu

ROOT="${FINANCE_IMPORT_ROOT:-.local/imports}"
ARCHIVE_DAYS="${FINANCE_ARCHIVE_RETENTION_DAYS:-180}"
REJECTED_DAYS="${FINANCE_REJECTED_RETENTION_DAYS:-90}"
APPLY="${RETENTION_APPLY:-0}"

case "$ARCHIVE_DAYS" in ''|*[!0-9]*) echo 'Invalid FINANCE_ARCHIVE_RETENTION_DAYS' >&2; exit 2 ;; esac
case "$REJECTED_DAYS" in ''|*[!0-9]*) echo 'Invalid FINANCE_REJECTED_RETENTION_DAYS' >&2; exit 2 ;; esac
[ "$ARCHIVE_DAYS" -ge 7 ] || { echo 'Archive retention must be at least 7 days' >&2; exit 2; }
[ "$REJECTED_DAYS" -ge 7 ] || { echo 'Rejected retention must be at least 7 days' >&2; exit 2; }
case "$APPLY" in 0|1) : ;; *) echo 'RETENTION_APPLY must be 0 or 1' >&2; exit 2 ;; esac

count_candidates() {
  dir="$1"; days="$2"
  [ -d "$dir" ] || { printf '0\n'; return; }
  find "$dir" -type f -mtime "+$days" -print | awk 'END {print NR+0}'
}

delete_candidates() {
  dir="$1"; days="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -mtime "+$days" -exec rm -f {} +
  # Remove only empty date buckets. Never remove the configured root itself.
  find "$dir" -mindepth 1 -type d -empty -exec rmdir {} + 2>/dev/null || true
}

archive_count="$(count_candidates "$ROOT/archive" "$ARCHIVE_DAYS")"
rejected_count="$(count_candidates "$ROOT/rejected" "$REJECTED_DAYS")"

printf 'RETENTION_PLAN archive_candidates=%s rejected_candidates=%s apply=%s\n' \
  "$archive_count" "$rejected_count" "$APPLY"

if [ "$APPLY" -eq 1 ]; then
  delete_candidates "$ROOT/archive" "$ARCHIVE_DAYS"
  delete_candidates "$ROOT/rejected" "$REJECTED_DAYS"
  remaining_archive="$(count_candidates "$ROOT/archive" "$ARCHIVE_DAYS")"
  remaining_rejected="$(count_candidates "$ROOT/rejected" "$REJECTED_DAYS")"
  [ "$remaining_archive" -eq 0 ] && [ "$remaining_rejected" -eq 0 ] || {
    echo 'Retention cleanup left expired candidates' >&2
    exit 3
  }
  echo 'RETENTION_CLEANUP=PASS'
else
  echo 'RETENTION_DRY_RUN=PASS'
fi
