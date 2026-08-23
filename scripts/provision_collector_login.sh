#!/usr/bin/env sh
set -eu

POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
CONTAINER_NAME="${FINANCE_DB_CONTAINER:-family-finance-postgres}"
COLLECTOR_DB_USER="${FINANCE_COLLECTOR_DB_USER:-finance_collector_client}"
COLLECTOR_SECRET_FILE="${FINANCE_COLLECTOR_SECRET_FILE:-.local/secrets/collector.env}"
COLLECTOR_CONNECTION_LIMIT="${FINANCE_COLLECTOR_CONNECTION_LIMIT:-4}"
COLLECTOR_STATEMENT_TIMEOUT="${FINANCE_COLLECTOR_STATEMENT_TIMEOUT:-10s}"
COLLECTOR_IDLE_TX_TIMEOUT="${FINANCE_COLLECTOR_IDLE_TX_TIMEOUT:-5s}"
COLLECTOR_LOCK_TIMEOUT="${FINANCE_COLLECTOR_LOCK_TIMEOUT:-2s}"

case "$COLLECTOR_DB_USER" in ''|[0-9]*|*[!a-z0-9_]*) echo 'Invalid FINANCE_COLLECTOR_DB_USER' >&2; exit 20 ;; esac
[ "${#COLLECTOR_DB_USER}" -le 63 ] || { echo 'FINANCE_COLLECTOR_DB_USER is too long' >&2; exit 20; }
case "$COLLECTOR_CONNECTION_LIMIT" in ''|*[!0-9]*) echo 'Invalid FINANCE_COLLECTOR_CONNECTION_LIMIT' >&2; exit 21 ;; esac
[ "$COLLECTOR_CONNECTION_LIMIT" -ge 1 ] && [ "$COLLECTOR_CONNECTION_LIMIT" -le 20 ] || { echo 'FINANCE_COLLECTOR_CONNECTION_LIMIT must be between 1 and 20' >&2; exit 21; }

find_docker() {
  if command -v docker >/dev/null 2>&1; then command -v docker; return 0; fi
  for candidate in /usr/local/bin/docker /usr/bin/docker /var/packages/ContainerManager/target/usr/bin/docker /var/packages/Docker/target/usr/bin/docker; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}
DOCKER_BIN="${DOCKER_BIN:-$(find_docker || true)}"
[ -n "$DOCKER_BIN" ] || { echo 'Docker CLI not found' >&2; exit 4; }
USE_SUDO=0
if "$DOCKER_BIN" info >/dev/null 2>&1; then :
elif command -v sudo >/dev/null 2>&1 && sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then USE_SUDO=1
else echo 'Docker is not available non-interactively' >&2; exit 5
fi
docker_cmd() { if [ "$USE_SUDO" -eq 1 ]; then sudo -n "$DOCKER_BIN" "$@"; else "$DOCKER_BIN" "$@"; fi; }

role_exists() {
  docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
    -c "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$COLLECTOR_DB_USER');"
}
read_secret_value() {
  key="$1"; file="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$file"
}

CREATED_SECRET=no
if [ -s "$COLLECTOR_SECRET_FILE" ]; then
  STORED_USER="$(read_secret_value FINANCE_COLLECTOR_DB_USER "$COLLECTOR_SECRET_FILE")"
  COLLECTOR_DB_PASSWORD="$(read_secret_value FINANCE_COLLECTOR_DB_PASSWORD "$COLLECTOR_SECRET_FILE")"
  [ "$STORED_USER" = "$COLLECTOR_DB_USER" ] || { echo 'collector secret file contains an unexpected role name' >&2; exit 22; }
  case "$COLLECTOR_DB_PASSWORD" in ''|*[!0-9a-fA-F]*) echo 'collector password is not a hex secret' >&2; exit 23 ;; esac
  [ "${#COLLECTOR_DB_PASSWORD}" -eq 64 ] || { echo 'collector password must contain 64 hex characters' >&2; exit 23; }
else
  if [ "$(role_exists)" = t ]; then
    echo 'collector database role exists but local secret file is missing; refusing implicit rotation' >&2
    exit 24
  fi
  command -v openssl >/dev/null 2>&1 || { echo 'openssl is required for first-time collector password generation' >&2; exit 25; }
  COLLECTOR_DB_PASSWORD="$(openssl rand -hex 32)"
  SECRET_DIR="$(dirname "$COLLECTOR_SECRET_FILE")"
  umask 077
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR" 2>/dev/null || true
  {
    printf 'FINANCE_COLLECTOR_DB_USER=%s\n' "$COLLECTOR_DB_USER"
    printf 'FINANCE_COLLECTOR_DB_PASSWORD=%s\n' "$COLLECTOR_DB_PASSWORD"
  } > "$COLLECTOR_SECRET_FILE"
  chmod 600 "$COLLECTOR_SECRET_FILE"
  CREATED_SECRET=yes
fi

docker_cmd exec -i "$CONTAINER_NAME" psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$COLLECTOR_DB_USER') THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $COLLECTOR_CONNECTION_LIMIT', '$COLLECTOR_DB_USER', '$COLLECTOR_DB_PASSWORD');
  ELSE
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $COLLECTOR_CONNECTION_LIMIT', '$COLLECTOR_DB_USER', '$COLLECTOR_DB_PASSWORD');
  END IF;
  EXECUTE format('REVOKE finance_app FROM %I', '$COLLECTOR_DB_USER');
  EXECUTE format('REVOKE finance_ai_reader FROM %I', '$COLLECTOR_DB_USER');
  EXECUTE format('REVOKE finance_ai_writer FROM %I', '$COLLECTOR_DB_USER');
  EXECUTE format('REVOKE finance_mcp_reader FROM %I', '$COLLECTOR_DB_USER');
  EXECUTE format('GRANT finance_collector TO %I', '$COLLECTOR_DB_USER');
  EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', '$COLLECTOR_DB_USER', '$COLLECTOR_STATEMENT_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', '$COLLECTOR_DB_USER', '$COLLECTOR_IDLE_TX_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET lock_timeout = %L', '$COLLECTOR_DB_USER', '$COLLECTOR_LOCK_TIMEOUT');
END
\$\$;
SQL

ROLE_FLAGS="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -F '|' -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname='$COLLECTOR_DB_USER';")"
[ "$ROLE_FLAGS" = 'f|f|f|f|f' ] || { echo "collector role unexpectedly has elevated flags: $ROLE_FLAGS" >&2; exit 30; }
IS_COLLECTOR="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT pg_has_role('$COLLECTOR_DB_USER','finance_collector','member');")"
IS_BROADER="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT pg_has_role('$COLLECTOR_DB_USER','finance_app','member') OR pg_has_role('$COLLECTOR_DB_USER','finance_ai_reader','member') OR pg_has_role('$COLLECTOR_DB_USER','finance_ai_writer','member') OR pg_has_role('$COLLECTOR_DB_USER','finance_mcp_reader','member');")"
CAN_STAGE="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT has_table_privilege('$COLLECTOR_DB_USER','ingest.collection_observations','INSERT');")"
CAN_LEDGER="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT has_table_privilege('$COLLECTOR_DB_USER','finance.transactions','INSERT');")"
[ "$IS_COLLECTOR" = t ] || { echo 'collector login is not a finance_collector member' >&2; exit 31; }
[ "$IS_BROADER" = f ] || { echo 'collector login unexpectedly has broader finance membership' >&2; exit 32; }
[ "$CAN_STAGE" = t ] || { echo 'collector login cannot insert staging observations' >&2; exit 33; }
[ "$CAN_LEDGER" = f ] || { echo 'collector login unexpectedly can mutate finance ledger' >&2; exit 34; }

LOGIN_CHECK="$(printf '%s\n' "$COLLECTOR_DB_PASSWORD" | docker_cmd exec -i "$CONTAINER_NAME" sh -c '
  IFS= read -r PGPASSWORD
  export PGPASSWORD
  exec psql -h 127.0.0.1 -qAt -v ON_ERROR_STOP=1 -U "$1" -d "$2" -c "SELECT current_user; SELECT COUNT(*) FROM finance.households;"
' sh "$COLLECTOR_DB_USER" "$POSTGRES_DB" 2>/dev/null)"
unset COLLECTOR_DB_PASSWORD
printf '%s\n' "$LOGIN_CHECK" | grep -qx "$COLLECTOR_DB_USER" || { echo 'collector TCP login user mismatch' >&2; exit 35; }

printf 'COLLECTOR_LOGIN_PROVISION=PASS role=%s secret_created=%s\n' "$COLLECTOR_DB_USER" "$CREATED_SECRET"
