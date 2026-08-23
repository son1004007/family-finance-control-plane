#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
BACKUP_DIR="${BACKUP_DIR:-.local/backups/postgres}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"

DOCKER_BIN="${DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
[ -n "$DOCKER_BIN" ] || { echo "Docker CLI not found; set DOCKER_BIN" >&2; exit 4; }

USE_SUDO=0
if "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=0
elif command -v sudo >/dev/null 2>&1 && sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=1
else
  echo "Docker is not available non-interactively" >&2
  exit 5
fi

docker_cmd() {
  if [ "$USE_SUDO" -eq 1 ]; then
    sudo -n "$DOCKER_BIN" "$@"
  else
    "$DOCKER_BIN" "$@"
  fi
}

compose() {
  docker_cmd compose -f "$COMPOSE_FILE" "$@"
}

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/family_finance.$STAMP.dump"
TMP_FILE="$BACKUP_FILE.tmp.$$"
VERIFY_DB="finance_restore_verify_$(date +%Y%m%d%H%M%S)_$$"
VERIFY_CREATED=0

cleanup() {
  rc=$?
  trap - EXIT INT TERM
  rm -f "$TMP_FILE" 2>/dev/null || true
  if [ "$VERIFY_CREATED" -eq 1 ]; then
    compose exec -T db dropdb --if-exists -U "$POSTGRES_ADMIN_USER" "$VERIFY_DB" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

compose exec -T db pg_isready -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" >/dev/null

compose exec -T db pg_dump \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  --format=custom --no-owner --no-privileges > "$TMP_FILE"

[ -s "$TMP_FILE" ] || { echo 'pg_dump produced an empty file' >&2; exit 10; }
mv "$TMP_FILE" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE" 2>/dev/null || true

count_table() {
  db="$1"
  table="$2"
  compose exec -T db psql -At -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_ADMIN_USER" -d "$db" -c "SELECT COUNT(*) FROM $table;"
}

PROD_MIGRATIONS="$(count_table "$POSTGRES_DB" meta.schema_migrations)"
PROD_ACCOUNTS="$(count_table "$POSTGRES_DB" finance.accounts)"
PROD_TRANSACTIONS="$(count_table "$POSTGRES_DB" finance.transactions)"
PROD_ASSETS="$(count_table "$POSTGRES_DB" finance.asset_snapshots)"
PROD_LIABILITIES="$(count_table "$POSTGRES_DB" finance.liability_snapshots)"

compose exec -T db createdb -U "$POSTGRES_ADMIN_USER" "$VERIFY_DB"
VERIFY_CREATED=1

cat "$BACKUP_FILE" | compose exec -T db pg_restore \
  -U "$POSTGRES_ADMIN_USER" -d "$VERIFY_DB" \
  --no-owner --no-privileges --exit-on-error

[ "$(count_table "$VERIFY_DB" meta.schema_migrations)" = "$PROD_MIGRATIONS" ] || { echo 'migration count mismatch after restore' >&2; exit 20; }
[ "$(count_table "$VERIFY_DB" finance.accounts)" = "$PROD_ACCOUNTS" ] || { echo 'account count mismatch after restore' >&2; exit 21; }
[ "$(count_table "$VERIFY_DB" finance.transactions)" = "$PROD_TRANSACTIONS" ] || { echo 'transaction count mismatch after restore' >&2; exit 22; }
[ "$(count_table "$VERIFY_DB" finance.asset_snapshots)" = "$PROD_ASSETS" ] || { echo 'asset count mismatch after restore' >&2; exit 23; }
[ "$(count_table "$VERIFY_DB" finance.liability_snapshots)" = "$PROD_LIABILITIES" ] || { echo 'liability count mismatch after restore' >&2; exit 24; }

compose exec -T db dropdb -U "$POSTGRES_ADMIN_USER" "$VERIFY_DB"
VERIFY_CREATED=0

ls -1t "$BACKUP_DIR"/family_finance.*.dump 2>/dev/null | awk -v keep="$BACKUP_KEEP" 'NR>keep' | while IFS= read -r old; do
  rm -f "$old"
done

if command -v sha256sum >/dev/null 2>&1; then
  BACKUP_SHA256="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  BACKUP_SHA256="$(shasum -a 256 "$BACKUP_FILE" | awk '{print $1}')"
else
  BACKUP_SHA256="unavailable"
fi

trap - EXIT INT TERM
printf 'POSTGRES_BACKUP_RESTORE=PASS\n'
printf 'BACKUP_FILE=%s\n' "$BACKUP_FILE"
printf 'BACKUP_SHA256=%s\n' "$BACKUP_SHA256"
