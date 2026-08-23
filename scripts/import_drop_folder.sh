#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
IMPORT_ROOT="${FINANCE_IMPORT_ROOT:-./.local/imports}"
RAW_DIR="$IMPORT_ROOT/raw"
MAPPING_DIR="$IMPORT_ROOT/mappings"
ARCHIVE_DIR="$IMPORT_ROOT/archive"
REJECTED_DIR="$IMPORT_ROOT/rejected"

umask 077
mkdir -p "$RAW_DIR" "$MAPPING_DIR" "$ARCHIVE_DIR" "$REJECTED_DIR"
chmod 700 "$IMPORT_ROOT" "$RAW_DIR" "$MAPPING_DIR" "$ARCHIVE_DIR" "$REJECTED_DIR" 2>/dev/null || true

find_mapping() {
  file="$1"
  base="$(basename "$file")"
  stem="${base%.*}"
  ext="${base##*.}"
  for candidate in \
    "$MAPPING_DIR/$base.mapping.json" \
    "$MAPPING_DIR/$stem.mapping.json" \
    "$MAPPING_DIR/default.$ext.mapping.json"; do
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

archive_file() {
  src="$1"; bucket="$2"
  day="$(date +%Y%m%d)"
  target_dir="$bucket/$day"
  mkdir -p "$target_dir"
  chmod 700 "$target_dir" 2>/dev/null || true
  base="$(basename "$src")"
  target="$target_dir/$base"
  if [ -e "$target" ]; then
    suffix="$(date +%H%M%S)-$$"
    target="$target_dir/$suffix-$base"
  fi
  mv "$src" "$target"
}

processed=0
completed=0
rejected=0
missing_mapping=0

for file in "$RAW_DIR"/*; do
  [ -f "$file" ] || continue
  case "$file" in
    *.csv|*.CSV|*.xlsx|*.XLSX) : ;;
    *) continue ;;
  esac
  processed=$((processed + 1))
  mapping="$(find_mapping "$file" || true)"
  if [ -z "$mapping" ]; then
    missing_mapping=$((missing_mapping + 1))
    rejected=$((rejected + 1))
    archive_file "$file" "$REJECTED_DIR"
    continue
  fi

  rc=0
  case "$file" in
    *.csv|*.CSV)
      sh "$SCRIPT_DIR/import_generic_csv.sh" "$file" "$mapping" >/dev/null 2>&1 || rc=$?
      ;;
    *.xlsx|*.XLSX)
      sh "$SCRIPT_DIR/import_generic_xlsx.sh" "$file" "$mapping" >/dev/null 2>&1 || rc=$?
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    completed=$((completed + 1))
    archive_file "$file" "$ARCHIVE_DIR"
  else
    rejected=$((rejected + 1))
    archive_file "$file" "$REJECTED_DIR"
  fi
done

printf 'DROP_IMPORT_SUMMARY processed=%s completed=%s rejected=%s missing_mapping=%s\n' \
  "$processed" "$completed" "$rejected" "$missing_mapping"
[ "$rejected" -eq 0 ] || exit 20
