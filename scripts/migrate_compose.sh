#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-compose.yaml}"
POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
MIGRATION_DIR="${MIGRATION_DIR:-db/migrations}"

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "No SHA-256 utility available" >&2
    exit 2
  fi
}

compose exec -T db psql -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE SCHEMA IF NOT EXISTS meta;
CREATE TABLE IF NOT EXISTS meta.schema_migrations (
  version TEXT PRIMARY KEY,
  checksum CHAR(64) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

for file in "$MIGRATION_DIR"/*.sql; do
  [ -f "$file" ] || continue
  version="$(basename "$file")"
  checksum="$(sha256_file "$file")"

  existing="$(printf '%s\n' "SELECT checksum FROM meta.schema_migrations WHERE version = :'version';" \
    | compose exec -T db psql -At -v ON_ERROR_STOP=1 \
        -v version="$version" \
        -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB")"

  if [ -n "$existing" ]; then
    if [ "$existing" != "$checksum" ]; then
      echo "Migration checksum mismatch: $version" >&2
      exit 3
    fi
    echo "SKIP $version"
    continue
  fi

  echo "APPLY $version"
  {
    printf '%s\n' 'BEGIN;'
    cat "$file"
    printf '\n%s\n' "INSERT INTO meta.schema_migrations(version, checksum) VALUES (:'version', :'checksum');"
    printf '%s\n' 'COMMIT;'
  } | compose exec -T db psql -v ON_ERROR_STOP=1 \
        -v version="$version" -v checksum="$checksum" \
        -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB"
done

echo "MIGRATIONS=PASS"
