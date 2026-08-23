#!/usr/bin/env sh
set -eu

POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
CONTAINER_NAME="${FINANCE_DB_CONTAINER:-family-finance-postgres}"
AI_DB_USER="${FINANCE_AI_DB_USER:-finance_ai_client}"
AI_SECRET_FILE="${FINANCE_AI_SECRET_FILE:-.local/secrets/ai-reader.env}"
AI_CONNECTION_LIMIT="${FINANCE_AI_CONNECTION_LIMIT:-5}"
AI_STATEMENT_TIMEOUT="${FINANCE_AI_STATEMENT_TIMEOUT:-30s}"
AI_IDLE_TX_TIMEOUT="${FINANCE_AI_IDLE_TX_TIMEOUT:-15s}"
AI_LOCK_TIMEOUT="${FINANCE_AI_LOCK_TIMEOUT:-5s}"

case "$AI_DB_USER" in
  ''|[0-9]*|*[!a-z0-9_]*) echo "Invalid FINANCE_AI_DB_USER" >&2; exit 20 ;;
esac
[ "${#AI_DB_USER}" -le 63 ] || { echo "FINANCE_AI_DB_USER is too long" >&2; exit 20; }
case "$AI_CONNECTION_LIMIT" in
  ''|*[!0-9]*) echo "Invalid FINANCE_AI_CONNECTION_LIMIT" >&2; exit 21 ;;
esac
[ "$AI_CONNECTION_LIMIT" -ge 1 ] || { echo "FINANCE_AI_CONNECTION_LIMIT must be >= 1" >&2; exit 21; }

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
[ -n "$DOCKER_BIN" ] || { echo 'Docker CLI not found' >&2; exit 4; }

USE_SUDO=0
if "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=0
elif command -v sudo >/dev/null 2>&1 && sudo -n "$DOCKER_BIN" info >/dev/null 2>&1; then
  USE_SUDO=1
else
  echo 'Docker is not available non-interactively' >&2
  exit 5
fi

docker_cmd() {
  if [ "$USE_SUDO" -eq 1 ]; then
    sudo -n "$DOCKER_BIN" "$@"
  else
    "$DOCKER_BIN" "$@"
  fi
}

role_exists() {
  docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
    -c "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$AI_DB_USER');"
}

read_secret_value() {
  key="$1"
  file="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}' "$file"
}

CREATED_SECRET=no
if [ -s "$AI_SECRET_FILE" ]; then
  STORED_USER="$(read_secret_value FINANCE_AI_DB_USER "$AI_SECRET_FILE")"
  AI_DB_PASSWORD="$(read_secret_value FINANCE_AI_DB_PASSWORD "$AI_SECRET_FILE")"
  [ "$STORED_USER" = "$AI_DB_USER" ] || {
    echo 'AI reader secret file contains an unexpected role name' >&2
    exit 22
  }
  case "$AI_DB_PASSWORD" in
    ''|*[!0-9a-fA-F]*) echo 'AI reader secret password is not a hex secret' >&2; exit 23 ;;
  esac
  [ "${#AI_DB_PASSWORD}" -eq 64 ] || {
    echo 'AI reader secret password must contain 64 hex characters' >&2
    exit 23
  }
else
  if [ "$(role_exists)" = 't' ]; then
    echo 'AI reader database role exists but its local secret file is missing; refusing implicit credential rotation' >&2
    exit 24
  fi
  command -v openssl >/dev/null 2>&1 || {
    echo 'openssl is required for first-time AI reader password generation' >&2
    exit 25
  }
  AI_DB_PASSWORD="$(openssl rand -hex 32)"
  SECRET_DIR="$(dirname "$AI_SECRET_FILE")"
  umask 077
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR" 2>/dev/null || true
  {
    printf 'FINANCE_AI_DB_USER=%s\n' "$AI_DB_USER"
    printf 'FINANCE_AI_DB_PASSWORD=%s\n' "$AI_DB_PASSWORD"
  } > "$AI_SECRET_FILE"
  chmod 600 "$AI_SECRET_FILE"
  CREATED_SECRET=yes
fi

# Role name and generated password are tightly validated above before interpolation.
docker_cmd exec -i "$CONTAINER_NAME" psql -q -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$AI_DB_USER') THEN
    EXECUTE format(
      'ALTER ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $AI_CONNECTION_LIMIT',
      '$AI_DB_USER', '$AI_DB_PASSWORD'
    );
  ELSE
    EXECUTE format(
      'CREATE ROLE %I WITH LOGIN PASSWORD %L CONNECTION LIMIT $AI_CONNECTION_LIMIT',
      '$AI_DB_USER', '$AI_DB_PASSWORD'
    );
  END IF;

  EXECUTE format('REVOKE finance_app FROM %I', '$AI_DB_USER');
  EXECUTE format('REVOKE finance_ai_writer FROM %I', '$AI_DB_USER');
  EXECUTE format('GRANT finance_ai_reader TO %I', '$AI_DB_USER');
  EXECUTE format('ALTER ROLE %I SET default_transaction_read_only = on', '$AI_DB_USER');
  EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', '$AI_DB_USER', '$AI_STATEMENT_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', '$AI_DB_USER', '$AI_IDLE_TX_TIMEOUT');
  EXECUTE format('ALTER ROLE %I SET lock_timeout = %L', '$AI_DB_USER', '$AI_LOCK_TIMEOUT');
END
\$\$;
SQL

ROLE_FLAGS="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -F '|' -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls FROM pg_roles WHERE rolname='$AI_DB_USER';")"
[ "$ROLE_FLAGS" = 'f|f|f|f|f' ] || {
  echo "AI reader role unexpectedly has elevated flags: $ROLE_FLAGS" >&2
  exit 30
}

IS_READER="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT pg_has_role('$AI_DB_USER','finance_ai_reader','member');")"
IS_WRITER="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT pg_has_role('$AI_DB_USER','finance_ai_writer','member') OR pg_has_role('$AI_DB_USER','finance_app','member');")"
CAN_INSERT="$(docker_cmd exec "$CONTAINER_NAME" psql -qAt -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT has_table_privilege('$AI_DB_USER','planning.goals','INSERT');")"
[ "$IS_READER" = 't' ] || { echo 'AI login is not a finance_ai_reader member' >&2; exit 31; }
[ "$IS_WRITER" = 'f' ] || { echo 'AI login unexpectedly has writer/app membership' >&2; exit 32; }
[ "$CAN_INSERT" = 'f' ] || { echo 'AI login unexpectedly has INSERT privilege' >&2; exit 33; }

# Verify password authentication over TCP inside the DB container. The password is
# sent through stdin, never a host process argument or sudo-preserved environment.
LOGIN_CHECK="$(
  printf '%s\n' "$AI_DB_PASSWORD" | docker_cmd exec -i "$CONTAINER_NAME" sh -c '
    IFS= read -r PGPASSWORD
    export PGPASSWORD
    exec psql -h 127.0.0.1 -qAt -v ON_ERROR_STOP=1 \
      -U "$1" -d "$2" \
      -c "SELECT current_user; SHOW transaction_read_only; SELECT COUNT(*) FROM analytics.v_current_employment;"
  ' sh "$AI_DB_USER" "$POSTGRES_DB" 2>/dev/null
)"
unset AI_DB_PASSWORD

printf '%s\n' "$LOGIN_CHECK" | grep -qx "$AI_DB_USER" || {
  echo 'AI reader TCP login did not authenticate as the expected role' >&2
  exit 34
}
printf '%s\n' "$LOGIN_CHECK" | grep -qx 'on' || {
  echo 'AI reader session is not read-only by default' >&2
  exit 35
}

printf 'AI_READER_LOGIN_PROVISION=PASS role=%s secret_created=%s\n' "$AI_DB_USER" "$CREATED_SECRET"
