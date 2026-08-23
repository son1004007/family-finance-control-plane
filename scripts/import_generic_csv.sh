#!/usr/bin/env sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <transactions.csv> <mapping.json>" >&2
  exit 2
fi

CSV_INPUT="$1"
MAPPING_INPUT="$2"
POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
CONTAINER_NAME="${FINANCE_DB_CONTAINER:-family-finance-postgres}"
PYTHON_IMAGE="${GENERIC_IMPORTER_PYTHON_IMAGE:-python:3.12-alpine}"

abs_file() {
  input="$1"
  dir="$(dirname "$input")"
  base="$(basename "$input")"
  (cd "$dir" >/dev/null 2>&1 && printf '%s/%s\n' "$(pwd -P)" "$base")
}

CSV_FILE="$(abs_file "$CSV_INPUT")"
MAPPING_FILE="$(abs_file "$MAPPING_INPUT")"
[ -f "$CSV_FILE" ] || { echo "CSV not found: $CSV_INPUT" >&2; exit 3; }
[ -f "$MAPPING_FILE" ] || { echo "Mapping not found: $MAPPING_INPUT" >&2; exit 3; }

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IMPORTER_DIR="$REPO_ROOT/importers/generic_csv"
[ -f "$IMPORTER_DIR/emit_copy_sql.py" ] || {
  echo 'generic CSV normalizer not found' >&2
  exit 4
}

find_docker() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi
  for candidate in \
    /usr/local/bin/docker \
    /usr/bin/docker \
    /var/packages/ContainerManager/target/usr/bin/docker \
    /var/packages/Docker/target/usr/bin/docker; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

DOCKER_BIN="${DOCKER_BIN:-$(find_docker || true)}"
[ -n "$DOCKER_BIN" ] || { echo 'Docker CLI not found' >&2; exit 5; }

USE_SUDO=0
if "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=0
elif command -v sudo >/dev/null 2>&1 && sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=1
else
  echo 'Docker is not available non-interactively' >&2
  exit 6
fi

docker_cmd() {
  if [ "$USE_SUDO" -eq 1 ]; then
    sudo -n "$DOCKER_BIN" "$@"
  else
    "$DOCKER_BIN" "$@"
  fi
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return
  fi
  echo 'No SHA-256 utility found' >&2
  exit 7
}

FILE_SHA="$(sha256_file "$CSV_FILE")"
MAPPING_SHA="$(sha256_file "$MAPPING_FILE")"
case "$FILE_SHA$MAPPING_SHA" in
  *[!0-9a-fA-F]*) echo 'Invalid SHA-256 output' >&2; exit 8 ;;
esac
[ "${#FILE_SHA}" -eq 64 ] && [ "${#MAPPING_SHA}" -eq 64 ] || {
  echo 'Invalid SHA-256 length' >&2
  exit 8
}

EXISTING="$(docker_cmd exec "$CONTAINER_NAME" psql -At -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT status FROM ingest.import_batches WHERE source_type='generic_csv' AND file_sha256='$FILE_SHA' AND mapping_sha256='$MAPPING_SHA' ORDER BY import_batch_id DESC LIMIT 1;" \
  2>/dev/null || true)"
if [ "$EXISTING" = 'completed' ]; then
  echo "IMPORT_ALREADY_APPLIED=PASS file_sha256=$FILE_SHA mapping_sha256=$MAPPING_SHA"
  exit 0
fi

umask 077
TMP_SQL="${TMPDIR:-/tmp}/family-finance-import.$$.sql"
cleanup() {
  rm -f "$TMP_SQL" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Normalize in a disposable Python container. The NAS host itself needs no Python package.
docker_cmd run --rm \
  -v "$IMPORTER_DIR:/app/importer:ro" \
  -v "$CSV_FILE:/input.csv:ro" \
  -v "$MAPPING_FILE:/mapping.json:ro" \
  "$PYTHON_IMAGE" \
  python /app/importer/emit_copy_sql.py \
  /input.csv /mapping.json "$FILE_SHA" "$MAPPING_SHA" > "$TMP_SQL"

[ -s "$TMP_SQL" ] || { echo 'Normalizer produced no SQL' >&2; exit 9; }

docker_cmd exec -i "$CONTAINER_NAME" psql -At -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" < "$TMP_SQL"

echo "GENERIC_CSV_IMPORT=PASS file_sha256=$FILE_SHA mapping_sha256=$MAPPING_SHA"
