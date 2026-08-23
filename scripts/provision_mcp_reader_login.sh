#!/usr/bin/env sh
set -eu

POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
CONTAINER_NAME="${FINANCE_DB_CONTAINER:-family-finance-postgres}"
MCP_DB_USER="${FINANCE_MCP_DB_USER:-finance_mcp_client}"
MCP_SECRET_FILE="${FINANCE_MCP_SECRET_FILE:-.local/secrets/mcp-reader.env}"
MCP_CONNECTION_LIMIT="${FINANCE_MCP_CONNECTION_LIMIT:-8}"
MCP_STATEMENT_TIMEOUT="${FINANCE_MCP_STATEMENT_TIMEOUT:-10s}"
MCP_IDLE_TX_TIMEOUT="${FINANCE_MCP_IDLE_TX_TIMEOUT:-5s}"
MCP_LOCK_TIMEOUT="${FINANCE_MCP_LOCK_TIMEOUT:-2s}"

case "$MCP_DB_USER" in ''|[0-9]*|*[!a-z0-9_]*) echo 'Invalid FINANCE_MCP_DB_USER' >&2; exit 20 ;; esac
[ "${#MCP_DB_USER}" -le 63 ] || { echo 'FINANCE_MCP_DB_USER is too long' >&2; exit 20; }
case "$MCP_CONNECTION_LIMIT" in ''|*[!0-9]*) echo 'Invalid FINANCE_MCP_CONNECTION_LIMIT' >&2; exit 21 ;; esac
[ "$MCP_CONNECTION_LIMIT" -ge 1 ] && [ "$MCP_CONNECTION_LIMIT" -le 50 ] || { echo 'FINANCE_MCP_CONNECTION_LIMIT must be between 1 and 50' >&2; exit 21; }

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
    -c "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$MCP_DB_USER');"
}
read_secret_value() {
  key="$1"; file="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$file"
}

CREATED_SECRET=no
if [ -s "$MCP_SECRET_FILE" ]; then
  STORED_USER="$(read_secret_value FINANCE_MCP_DB_USER "$MCP_SECRET_FILE")"
  MCP_DB_PASSWORD="$(read_secret_value FINANCE_MCP_DB_PASSWORD "$MCP_SECRET_FILE")"
  [ "$STORED_USER" = "$MCP_DB_USER" ] || { echo 'MCP reader secret file contains an unexpected role name' >&2; exit 22; }
  case "$MCP_DB_PASSWORD" in ''|*[!0-9a-fA-F]*) echo 'MCP reader password is not a hex secret' >&2; exit 23 ;; esac
  [ "${#MCP_DB_PASSWORD}" -eq 64 ] || { echo 'MCP reader password must contain 64 hex characters' >&2; exit 23; }
else
  if [ "$(role_exists)" = t ]; then
    echo 'MCP database role exists but its local secret file is missing; refusing implicit credential rotation' >&2
    exit 24
  fi
  command -v openssl >/dev/null 2>&1 || { echo 'openssl is required for first-time MCP password generation' >&2; exit 25; }
  MCP_DB_PASSWORD="$(openssl rand -hex 32)"
  SECRET_DIR="$(dirname "$MCP_SECRET_FILE")"
  umask 077
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR" 2>/dev/null || true
  {
    printf 'FINANCE_MCP_DB_USER=%s\n' "$MCP_DB_USER"
    printf 'FINANCE_MCP_DB_PASSWORD=%s\n' "$MCP_DB_PASSWORD"
  } > "$MCP_SECRET_FILE"
  chmod 600 "$MCP_SECRET_FILE"
  CREATED_SECRET=yes
fi

# User name/password are validated before SQL interpolation. Password never appears
# in process arguments or output.
docker_cmd exec -i "$CONTAINER_NAME" psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$MCP_DB_USER') THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $MCP_CONNECTION_LIMIT', '$MCP_DB_USER', '$MCP_DB_PASSWORD');
  ELSE
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $MCP_CONNECTION_LIMIT', '$MCP_DB_USER', '$MCP_DB_PASSWORD');
  END IF;
  EXECUTE format('REVOKE finance_app FROM %I', '$MCP_DB_USER');
  EXECUTE format('REVOKE finance_ai_reader FROM %I', '$MCP_DB_USER');
  EXECUTE format('REVOKE finance_ai_writer FROM %I', '$MCP_DB_USER');
  EXECUTE format('GRANT finance_mcp_reader TO %I', '$MCP_DB_USER');
  EXECUTE format('ALTER ROLE %I SET default_transaction_read_only = on', '$MCP_DB_USER');
  EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', '$MCP_DB_USER', '$MCP_STATEMENT_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', '$MCP_DB_USER', '$MCP_IDLE_TX_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET lock_timeout = %L', '$MCP_DB_USER', '$MCP_LOCK_TIMEOUT');
END
\$\$;
SQL

ROLE_FLAGS="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -F '|' -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname='$MCP_DB_USER';")"
[ "$ROLE_FLAGS" = 'f|f|f|f|f' ] || { echo "MCP reader role unexpectedly has elevated flags: $ROLE_FLAGS" >&2; exit 30; }
IS_MCP="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT pg_has_role('$MCP_DB_USER','finance_mcp_reader','member');")"
IS_BROADER="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT pg_has_role('$MCP_DB_USER','finance_ai_reader','member') OR pg_has_role('$MCP_DB_USER','finance_ai_writer','member') OR pg_has_role('$MCP_DB_USER','finance_app','member');")"
CAN_RAW="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT has_table_privilege('$MCP_DB_USER','finance.transactions','SELECT');")"
CAN_CURATED="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c "SELECT has_table_privilege('$MCP_DB_USER','analytics.v_household_financial_snapshot_by_currency','SELECT');")"
[ "$IS_MCP" = t ] || { echo 'MCP login is not a finance_mcp_reader member' >&2; exit 31; }
[ "$IS_BROADER" = f ] || { echo 'MCP login unexpectedly has broader finance membership' >&2; exit 32; }
[ "$CAN_RAW" = f ] || { echo 'MCP login unexpectedly has raw transaction SELECT' >&2; exit 33; }
[ "$CAN_CURATED" = t ] || { echo 'MCP login cannot read curated analytics' >&2; exit 34; }

# Authenticate through TCP inside the DB container. Pass the secret on stdin to a
# short shell so it never appears in the docker/psql process argument list.
LOGIN_CHECK="$(printf '%s\n' "$MCP_DB_PASSWORD" | docker_cmd exec -i "$CONTAINER_NAME" sh -c '
  IFS= read -r PGPASSWORD
  export PGPASSWORD
  exec psql -h 127.0.0.1 -qAt -v ON_ERROR_STOP=1 -U "$1" -d "$2" \
    -c "SELECT current_user; SHOW transaction_read_only; SELECT COUNT(*) FROM analytics.v_household_directory;"
' sh "$MCP_DB_USER" "$POSTGRES_DB" 2>/dev/null)"
unset MCP_DB_PASSWORD

printf '%s\n' "$LOGIN_CHECK" | grep -qx "$MCP_DB_USER" || { echo 'MCP reader TCP login user mismatch' >&2; exit 35; }
printf '%s\n' "$LOGIN_CHECK" | grep -qx on || { echo 'MCP reader session is not read-only by default' >&2; exit 36; }

printf 'MCP_READER_LOGIN_PROVISION=PASS role=%s secret_created=%s\n' "$MCP_DB_USER" "$CREATED_SECRET"
