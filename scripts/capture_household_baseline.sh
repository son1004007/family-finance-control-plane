#!/usr/bin/env sh
set -eu

POSTGRES_DB="${POSTGRES_DB:-family_finance}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-finance_admin}"
CONTAINER_NAME="${FINANCE_DB_CONTAINER:-family-finance-postgres}"
BASELINE_TIMEZONE_OFFSET="${BASELINE_TIMEZONE_OFFSET:-+00:00}"
NONINTERACTIVE="${BASELINE_NONINTERACTIVE:-0}"

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

prompt_value() {
  current="$1"
  label="$2"
  default_value="${3:-}"
  required="${4:-1}"

  if [ -n "$current" ]; then
    printf '%s' "$current"
    return 0
  fi

  if [ "$NONINTERACTIVE" = '1' ]; then
    if [ -n "$default_value" ] || [ "$required" = '0' ]; then
      printf '%s' "$default_value"
      return 0
    fi
    echo "Missing required noninteractive value: $label" >&2
    exit 20
  fi

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$label" "$default_value" >&2
  elif [ "$required" = '0' ]; then
    printf '%s [blank if none]: ' "$label" >&2
  else
    printf '%s: ' "$label" >&2
  fi

  IFS= read -r entered
  if [ -n "$entered" ]; then
    printf '%s' "$entered"
  else
    if [ -z "$default_value" ] && [ "$required" = '1' ]; then
      echo "A value is required: $label" >&2
      exit 20
    fi
    printf '%s' "$default_value"
  fi
}

validate_date() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || {
    echo "Invalid date: $1" >&2
    exit 21
  }
}

validate_status() {
  case "$1" in
    employed|self_employed|career_break|unemployed|leave|other) ;;
    *) echo "Invalid employment status: $1" >&2; exit 22 ;;
  esac
}

validate_money() {
  label="$1"
  value="$2"
  allow_blank="${3:-0}"
  if [ -z "$value" ] && [ "$allow_blank" = '1' ]; then
    return 0
  fi
  printf '%s\n' "$value" | grep -Eq '^[0-9]+([.][0-9]{1,2})?$' || {
    echo "Invalid non-negative money value for $label: $value" >&2
    exit 23
  }
}

printf '%s\n' 'Family Finance baseline capture'
printf '%s\n' 'Values are sent only to the local PostgreSQL container; this script does not upload them to GitHub.'
printf '%s\n' 'Use mutually exclusive asset amounts to avoid double counting.'

TODAY="$(date +%F)"
BASELINE_AS_OF_DATE="$(prompt_value "${BASELINE_AS_OF_DATE:-}" 'As-of date (YYYY-MM-DD)' "$TODAY")"
ADULT1_STATUS="$(prompt_value "${ADULT1_STATUS:-}" 'adult_1 employment status' 'employed')"
ADULT1_ANNUAL_GROSS="$(prompt_value "${ADULT1_ANNUAL_GROSS:-}" 'adult_1 annual gross income')"
ADULT1_MONTHLY_NET="$(prompt_value "${ADULT1_MONTHLY_NET:-}" 'adult_1 monthly net income')"
ADULT2_STATUS="$(prompt_value "${ADULT2_STATUS:-}" 'adult_2 employment status' 'career_break')"
ADULT2_ANNUAL_GROSS="$(prompt_value "${ADULT2_ANNUAL_GROSS:-}" 'adult_2 annual gross income' '' 0)"
ADULT2_MONTHLY_NET="$(prompt_value "${ADULT2_MONTHLY_NET:-}" 'adult_2 monthly net income' '' 0)"
LIQUID_CASH="$(prompt_value "${LIQUID_CASH:-}" 'Liquid cash and demand/savings deposits total')"
HOUSING_ASSET="$(prompt_value "${HOUSING_ASSET:-}" 'Housing-related asset value (deposit or owned-home value, no overlap)')"
INVESTMENT_ASSETS="$(prompt_value "${INVESTMENT_ASSETS:-}" 'Investment assets total (exclude cash counted above)')"
OTHER_ASSETS="$(prompt_value "${OTHER_ASSETS:-}" 'Other assets total (exclude all above)')"
TOTAL_DEBT="$(prompt_value "${TOTAL_DEBT:-}" 'Outstanding debt principal total')"
MONTHLY_RECURRING_SPEND="$(prompt_value "${MONTHLY_RECURRING_SPEND:-}" 'Ordinary recurring monthly household spend')"

validate_date "$BASELINE_AS_OF_DATE"
validate_status "$ADULT1_STATUS"
validate_status "$ADULT2_STATUS"
validate_money ADULT1_ANNUAL_GROSS "$ADULT1_ANNUAL_GROSS"
validate_money ADULT1_MONTHLY_NET "$ADULT1_MONTHLY_NET"
validate_money ADULT2_ANNUAL_GROSS "$ADULT2_ANNUAL_GROSS" 1
validate_money ADULT2_MONTHLY_NET "$ADULT2_MONTHLY_NET" 1
validate_money LIQUID_CASH "$LIQUID_CASH"
validate_money HOUSING_ASSET "$HOUSING_ASSET"
validate_money INVESTMENT_ASSETS "$INVESTMENT_ASSETS"
validate_money OTHER_ASSETS "$OTHER_ASSETS"
validate_money TOTAL_DEBT "$TOTAL_DEBT"
validate_money MONTHLY_RECURRING_SPEND "$MONTHLY_RECURRING_SPEND"
printf '%s\n' "$BASELINE_TIMEZONE_OFFSET" | grep -Eq '^[+-][0-9]{2}:[0-9]{2}$' || {
  echo "Invalid BASELINE_TIMEZONE_OFFSET: $BASELINE_TIMEZONE_OFFSET" >&2
  exit 24
}

ADULT2_ANNUAL_SQL="${ADULT2_ANNUAL_GROSS:-NULL}"
ADULT2_MONTHLY_SQL="${ADULT2_MONTHLY_NET:-NULL}"
BASELINE_TS="${BASELINE_AS_OF_DATE} 23:59:59${BASELINE_TIMEZONE_OFFSET}"

if command -v openssl >/dev/null 2>&1; then
  BATCH_HASH="$(printf 'nas-manual-baseline:%s' "$BASELINE_AS_OF_DATE" | openssl dgst -sha256 | awk '{print $NF}')"
elif command -v sha256sum >/dev/null 2>&1; then
  BATCH_HASH="$(printf 'nas-manual-baseline:%s' "$BASELINE_AS_OF_DATE" | sha256sum | awk '{print $1}')"
else
  echo 'openssl or sha256sum is required for baseline provenance hash' >&2
  exit 25
fi

[ "${#BATCH_HASH}" -eq 64 ] || { echo 'Unable to generate baseline provenance hash' >&2; exit 26; }

docker_cmd exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" <<SQL
BEGIN;

INSERT INTO ingest.import_batches(
  source_type, source_name, file_sha256, status, row_count, completed_at
)
VALUES (
  'manual_baseline', 'nas_interactive', '$BATCH_HASH', 'completed', 8, now()
)
ON CONFLICT (file_sha256) DO UPDATE
SET status = 'completed', row_count = EXCLUDED.row_count, completed_at = now();

INSERT INTO finance.households(label, base_currency)
VALUES ('primary_household', 'KRW')
ON CONFLICT (label) DO NOTHING;

INSERT INTO finance.persons(household_id, role_label)
SELECT household_id, role_label
FROM finance.households
CROSS JOIN (VALUES ('adult_1'), ('adult_2')) AS roles(role_label)
WHERE label = 'primary_household'
ON CONFLICT (household_id, role_label) DO NOTHING;

INSERT INTO finance.employment_snapshots(
  household_id, person_id, employment_status,
  annual_gross_income, monthly_net_income, currency,
  as_of_date, source_label
)
SELECT h.household_id, p.person_id, x.status, x.annual_gross, x.monthly_net,
       'KRW', DATE '$BASELINE_AS_OF_DATE', 'nas_manual_baseline'
FROM finance.households h
JOIN finance.persons p ON p.household_id = h.household_id
JOIN (VALUES
  ('adult_1', '$ADULT1_STATUS', $ADULT1_ANNUAL_GROSS::numeric, $ADULT1_MONTHLY_NET::numeric),
  ('adult_2', '$ADULT2_STATUS', $ADULT2_ANNUAL_SQL::numeric, $ADULT2_MONTHLY_SQL::numeric)
) AS x(person_role, status, annual_gross, monthly_net)
  ON p.role_label = x.person_role
WHERE h.label = 'primary_household'
ON CONFLICT (person_id, as_of_date) DO UPDATE
SET employment_status = EXCLUDED.employment_status,
    annual_gross_income = EXCLUDED.annual_gross_income,
    monthly_net_income = EXCLUDED.monthly_net_income,
    currency = EXCLUDED.currency,
    source_label = EXCLUDED.source_label;

INSERT INTO finance.accounts(household_id, account_type, account_label, currency)
SELECT household_id, 'aggregate_cash', 'baseline_liquid_cash', 'KRW'
FROM finance.households
WHERE label = 'primary_household'
ON CONFLICT (household_id, account_label) DO NOTHING;

INSERT INTO finance.account_balance_snapshots(
  account_id, balance_at, balance, currency, import_batch_id
)
SELECT a.account_id, TIMESTAMPTZ '$BASELINE_TS', $LIQUID_CASH::numeric, 'KRW', b.import_batch_id
FROM finance.accounts a
JOIN finance.households h ON h.household_id = a.household_id
JOIN ingest.import_batches b ON b.file_sha256 = '$BATCH_HASH'
WHERE h.label = 'primary_household' AND a.account_label = 'baseline_liquid_cash'
ON CONFLICT (account_id, balance_at) DO UPDATE
SET balance = EXCLUDED.balance, import_batch_id = EXCLUDED.import_batch_id;

INSERT INTO finance.asset_snapshots(
  household_id, asset_type, asset_label, valued_at,
  market_value, liquid_value, currency, import_batch_id
)
SELECT h.household_id, x.asset_type, x.asset_label, TIMESTAMPTZ '$BASELINE_TS',
       x.market_value, x.liquid_value, 'KRW', b.import_batch_id
FROM finance.households h
JOIN ingest.import_batches b ON b.file_sha256 = '$BATCH_HASH'
CROSS JOIN (VALUES
  ('housing', 'baseline_housing_asset', $HOUSING_ASSET::numeric, 0::numeric),
  ('investment', 'baseline_investment_assets', $INVESTMENT_ASSETS::numeric, $INVESTMENT_ASSETS::numeric),
  ('other', 'baseline_other_assets', $OTHER_ASSETS::numeric, 0::numeric)
) AS x(asset_type, asset_label, market_value, liquid_value)
WHERE h.label = 'primary_household'
ON CONFLICT (household_id, asset_label, valued_at) DO UPDATE
SET market_value = EXCLUDED.market_value,
    liquid_value = EXCLUDED.liquid_value,
    import_batch_id = EXCLUDED.import_batch_id;

INSERT INTO finance.liability_snapshots(
  household_id, liability_type, liability_label, valued_at,
  principal_balance, currency, import_batch_id
)
SELECT h.household_id, 'aggregate_debt', 'baseline_total_debt', TIMESTAMPTZ '$BASELINE_TS',
       $TOTAL_DEBT::numeric, 'KRW', b.import_batch_id
FROM finance.households h
JOIN ingest.import_batches b ON b.file_sha256 = '$BATCH_HASH'
WHERE h.label = 'primary_household'
ON CONFLICT (household_id, liability_label, valued_at) DO UPDATE
SET principal_balance = EXCLUDED.principal_balance,
    import_batch_id = EXCLUDED.import_batch_id;

DELETE FROM finance.recurring_obligations r
USING finance.households h
WHERE r.household_id = h.household_id
  AND h.label = 'primary_household'
  AND r.label = 'baseline_total_monthly_spend'
  AND r.starts_on = DATE '$BASELINE_AS_OF_DATE';

UPDATE finance.recurring_obligations r
SET active = false,
    ends_on = DATE '$BASELINE_AS_OF_DATE' - 1
FROM finance.households h
WHERE r.household_id = h.household_id
  AND h.label = 'primary_household'
  AND r.label = 'baseline_total_monthly_spend'
  AND r.active
  AND (r.starts_on IS NULL OR r.starts_on < DATE '$BASELINE_AS_OF_DATE');

INSERT INTO finance.recurring_obligations(
  household_id, label, category, monthly_amount, currency, starts_on, active
)
SELECT household_id, 'baseline_total_monthly_spend', 'baseline_total',
       $MONTHLY_RECURRING_SPEND::numeric, 'KRW', DATE '$BASELINE_AS_OF_DATE', true
FROM finance.households
WHERE label = 'primary_household';

COMMIT;
SQL

printf '\n%s\n' 'Baseline verification (local NAS output):'
docker_cmd exec "$CONTAINER_NAME" psql -P pager=off -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
  -c "SELECT h.label AS household, i.currency, i.annual_gross_income, i.monthly_net_income, i.earning_adult_count, i.latest_as_of_date FROM analytics.v_current_household_income_by_currency i JOIN finance.households h USING (household_id) WHERE h.label='primary_household';" \
  -c "SELECT h.label AS household, n.currency, n.account_balances, n.other_assets, n.liabilities, n.net_worth FROM analytics.v_net_worth_by_currency n JOIN finance.households h USING (household_id) WHERE h.label='primary_household';" \
  -c "SELECT h.label AS household, r.currency, r.monthly_fixed_obligations FROM analytics.v_active_recurring_obligations r JOIN finance.households h USING (household_id) WHERE h.label='primary_household';"

printf '%s\n' "BASELINE_CAPTURE=PASS as_of=$BASELINE_AS_OF_DATE"
