#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

PROJECT="${SYNTHETIC_E2E_PROJECT:-family-finance-synthetic-e2e}"
export COMPOSE_PROJECT_NAME="$PROJECT"
export POSTGRES_DB=family_finance
export POSTGRES_ADMIN_USER=finance_admin
export POSTGRES_ADMIN_PASSWORD=synthetic-e2e-only
export FINANCE_DB_CONTAINER="${PROJECT}-postgres"
export FINANCE_MCP_CONTAINER="${PROJECT}-mcp"
export FINANCE_MCP_SECRET_FILE="${TMPDIR:-/tmp}/${PROJECT}-mcp-reader.env"
PYTHON_IMAGE="${GENERIC_IMPORTER_PYTHON_IMAGE:-python:3.12-alpine}"
XLSX_FILE="${TMPDIR:-/tmp}/${PROJECT}-transactions.xlsx"

cleanup() {
  rm -f "$FINANCE_MCP_SECRET_FILE" "$XLSX_FILE" 2>/dev/null || true
  docker compose -f compose.yaml -f compose.mcp.yaml down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

case "$PROJECT" in
  family-finance-synthetic-e2e|family-finance-synthetic-e2e-*) : ;;
  *) echo 'SYNTHETIC_E2E_PROJECT must start with family-finance-synthetic-e2e' >&2; exit 2 ;;
esac

rm -f "$FINANCE_MCP_SECRET_FILE" "$XLSX_FILE" 2>/dev/null || true
docker compose -f compose.yaml -f compose.mcp.yaml down -v --remove-orphans >/dev/null 2>&1 || true
docker compose up -d db

for i in $(seq 1 30); do
  if docker exec "$FINANCE_DB_CONTAINER" pg_isready -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then break; fi
  [ "$i" -lt 30 ] || { docker logs "$FINANCE_DB_CONTAINER"; exit 3; }
  sleep 2
done

COMPOSE_FILE=compose.yaml sh scripts/migrate_compose.sh
for fixture in \
  db/fixtures/synthetic_household.sql \
  db/fixtures/synthetic_metrics.sql \
  db/fixtures/synthetic_history.sql \
  db/fixtures/synthetic_scenarios.sql; do
  docker exec -i "$FINANCE_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" < "$fixture"
done

sh scripts/import_generic_csv.sh tests/fixtures/synthetic/generic_bank.csv tests/fixtures/synthetic/generic_bank_mapping.json >/dev/null

REPO_ABS="$(pwd -P)"
docker run --rm \
  -v "$REPO_ABS:/workspace:ro" \
  -v "$(dirname "$XLSX_FILE"):/output" \
  "$PYTHON_IMAGE" \
  python /workspace/tests/fixtures/synthetic/generate_generic_bank_xlsx.py \
    /workspace/tests/fixtures/synthetic/generic_bank.csv "/output/$(basename "$XLSX_FILE")"
sh scripts/import_generic_xlsx.sh "$XLSX_FILE" tests/fixtures/synthetic/generic_bank_xlsx_mapping.json >/dev/null

docker exec -i "$FINANCE_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" < db/tests/assert_extended_metrics.sql >/dev/null

sh scripts/provision_mcp_reader_login.sh >/dev/null
set -a
. "$FINANCE_MCP_SECRET_FILE"
set +a

docker compose -f compose.yaml -f compose.mcp.yaml up -d --build mcp
for i in $(seq 1 30); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$FINANCE_MCP_CONTAINER" 2>/dev/null || true)"
  [ "$status" = healthy ] && break
  [ "$i" -lt 30 ] || { docker logs "$FINANCE_MCP_CONTAINER"; exit 4; }
  sleep 2
done

if ! docker exec -i "$FINANCE_MCP_CONTAINER" python - <<'PY'
import asyncio
from mcp import Client


def rows(result):
    assert not result.is_error, result.content
    assert result.structured_content is not None, result.content
    return result.structured_content['rows']


async def main():
    async with Client('http://127.0.0.1:8000/mcp') as client:
        tools = await client.list_tools()
        assert len(tools.tools) == 7
        snap = rows(await client.call_tool('financial_snapshot', {'household_label':'synthetic_household','currency':'KRW'}))
        assert snap[0]['net_worth'] == '18000000.00'
        reserve = rows(await client.call_tool('emergency_reserve', {'household_label':'synthetic_household','currency':'KRW'}))
        assert reserve[0]['coverage_months'] == '100.00'
        scenarios = rows(await client.call_tool('scenario_outcomes', {'household_label':'synthetic_household','currency':'KRW'}))
        assert scenarios[0]['annual_net_after_modeled_costs'] == '60520000.00'

asyncio.run(main())
PY
then
  docker logs "$FINANCE_MCP_CONTAINER" 2>&1 | grep -E 'mcp_tool_(complete|failed)|ERROR|Traceback' || true
  exit 6
fi

migration_count="$(docker exec "$FINANCE_DB_CONTAINER" psql -qAt -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -c 'SELECT COUNT(*) FROM meta.schema_migrations;')"
[ "$migration_count" -ge 8 ] || { echo "unexpected migration count: $migration_count" >&2; exit 5; }

echo "SYNTHETIC_E2E_MIGRATIONS=$migration_count"
echo 'SYNTHETIC_E2E_IMPORTS=PASS'
echo 'SYNTHETIC_E2E_ANALYTICS=PASS'
echo 'SYNTHETIC_E2E_MCP=PASS'
echo 'SYNTHETIC_E2E=PASS'
