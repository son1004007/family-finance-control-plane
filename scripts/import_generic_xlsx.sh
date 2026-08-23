#!/usr/bin/env sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <transactions.xlsx> <mapping.json>" >&2
  exit 2
fi

XLSX_INPUT="$1"
MAPPING_INPUT="$2"
PYTHON_IMAGE="${GENERIC_IMPORTER_PYTHON_IMAGE:-python:3.12-alpine}"

abs_file() {
  input="$1"; dir="$(dirname "$input")"; base="$(basename "$input")"
  (cd "$dir" >/dev/null 2>&1 && printf '%s/%s\n' "$(pwd -P)" "$base")
}
sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file" | awk '{print $1}'; return; fi
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$file" | awk '{print $1}'; return; fi
  if command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$file" | awk '{print $NF}'; return; fi
  echo 'No SHA-256 utility found' >&2; exit 7
}
find_docker() {
  if command -v docker >/dev/null 2>&1; then command -v docker; return 0; fi
  for candidate in /usr/local/bin/docker /usr/bin/docker /var/packages/ContainerManager/target/usr/bin/docker /var/packages/Docker/target/usr/bin/docker; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

XLSX_FILE="$(abs_file "$XLSX_INPUT")"
MAPPING_FILE="$(abs_file "$MAPPING_INPUT")"
[ -f "$XLSX_FILE" ] || { echo "XLSX not found: $XLSX_INPUT" >&2; exit 3; }
[ -f "$MAPPING_FILE" ] || { echo "Mapping not found: $MAPPING_INPUT" >&2; exit 3; }
case "$(basename "$XLSX_FILE")" in *.xlsx|*.XLSX) : ;; *) echo 'Input must be .xlsx' >&2; exit 3 ;; esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONVERTER_DIR="$REPO_ROOT/importers/generic_xlsx"
[ -f "$CONVERTER_DIR/xlsx_to_csv.py" ] || { echo 'XLSX converter not found' >&2; exit 4; }
[ -f "$SCRIPT_DIR/import_generic_csv.sh" ] || { echo 'CSV importer not found' >&2; exit 4; }

DOCKER_BIN="${DOCKER_BIN:-$(find_docker || true)}"
[ -n "$DOCKER_BIN" ] || { echo 'Docker CLI not found' >&2; exit 5; }
USE_SUDO=0
if "$DOCKER_BIN" info >/dev/null 2>&1; then :
elif command -v sudo >/dev/null 2>&1 && sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then USE_SUDO=1
else echo 'Docker is not available non-interactively' >&2; exit 6
fi
docker_cmd() { if [ "$USE_SUDO" -eq 1 ]; then sudo -n "$DOCKER_BIN" "$@"; else "$DOCKER_BIN" "$@"; fi; }

FILE_SHA="$(sha256_file "$XLSX_FILE")"
umask 077
TMP_DIR="${TMPDIR:-/tmp}/family-finance-xlsx.$$"
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

docker_cmd run --rm \
  -v "$CONVERTER_DIR:/app/converter:ro" \
  -v "$XLSX_FILE:/input.xlsx:ro" \
  -v "$MAPPING_FILE:/mapping.json:ro" \
  -v "$TMP_DIR:/output" \
  "$PYTHON_IMAGE" \
  python /app/converter/xlsx_to_csv.py /input.xlsx /mapping.json /output/normalized.csv

[ -s "$TMP_DIR/normalized.csv" ] || { echo 'XLSX conversion produced no CSV' >&2; exit 8; }

GENERIC_IMPORT_SOURCE_TYPE=generic_xlsx \
GENERIC_IMPORT_FILE_SHA="$FILE_SHA" \
GENERIC_IMPORT_ORIGINAL_FILENAME="$(basename "$XLSX_FILE")" \
GENERIC_IMPORT_NORMALIZER_VERSION=generic_xlsx_v1 \
DOCKER_BIN="$DOCKER_BIN" \
sh "$SCRIPT_DIR/import_generic_csv.sh" "$TMP_DIR/normalized.csv" "$MAPPING_FILE"

echo "GENERIC_XLSX_IMPORT=PASS file_sha256=$FILE_SHA"
