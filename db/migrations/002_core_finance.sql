CREATE TABLE ingest.import_batches (
  import_batch_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_type TEXT NOT NULL,
  source_name TEXT NOT NULL,
  original_filename TEXT,
  file_sha256 CHAR(64) NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'started' CHECK (status IN ('started', 'completed', 'failed', 'partial')),
  row_count INTEGER NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  error_count INTEGER NOT NULL DEFAULT 0 CHECK (error_count >= 0),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ingest.source_rows (
  source_row_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  import_batch_id BIGINT NOT NULL REFERENCES ingest.import_batches(import_batch_id) ON DELETE CASCADE,
  source_row_number INTEGER NOT NULL CHECK (source_row_number > 0),
  source_row_hash CHAR(64) NOT NULL,
  raw_payload JSONB NOT NULL,
  normalized BOOLEAN NOT NULL DEFAULT false,
  normalization_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (import_batch_id, source_row_number),
  UNIQUE (import_batch_id, source_row_hash)
);

CREATE TABLE finance.households (
  household_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  label TEXT NOT NULL UNIQUE,
  base_currency CHAR(3) NOT NULL DEFAULT 'KRW',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (base_currency ~ '^[A-Z]{3}$')
);

CREATE TABLE finance.persons (
  person_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  role_label TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, role_label)
);

CREATE TABLE finance.institutions (
  institution_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  institution_type TEXT NOT NULL,
  display_label TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (institution_type, display_label)
);

CREATE TABLE finance.accounts (
  account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  owner_person_id BIGINT REFERENCES finance.persons(person_id) ON DELETE SET NULL,
  institution_id BIGINT REFERENCES finance.institutions(institution_id) ON DELETE SET NULL,
  account_type TEXT NOT NULL,
  account_label TEXT NOT NULL,
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  external_ref_hash TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, account_label),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE TABLE finance.account_balance_snapshots (
  account_balance_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id BIGINT NOT NULL REFERENCES finance.accounts(account_id) ON DELETE CASCADE,
  balance_at TIMESTAMPTZ NOT NULL,
  balance NUMERIC(20,2) NOT NULL,
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  import_batch_id BIGINT REFERENCES ingest.import_batches(import_batch_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, balance_at),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE TABLE finance.transactions (
  transaction_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id BIGINT NOT NULL REFERENCES finance.accounts(account_id) ON DELETE CASCADE,
  occurred_at TIMESTAMPTZ NOT NULL,
  booked_on DATE,
  amount NUMERIC(20,2) NOT NULL,
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  category TEXT,
  counterparty TEXT,
  description TEXT,
  source_row_hash CHAR(64),
  import_batch_id BIGINT REFERENCES ingest.import_batches(import_batch_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE UNIQUE INDEX uq_transactions_account_source_hash
  ON finance.transactions(account_id, source_row_hash)
  WHERE source_row_hash IS NOT NULL;
CREATE INDEX ix_transactions_account_occurred_at
  ON finance.transactions(account_id, occurred_at DESC);

CREATE TABLE finance.income_events (
  income_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  person_id BIGINT REFERENCES finance.persons(person_id) ON DELETE SET NULL,
  occurred_on DATE NOT NULL,
  income_type TEXT NOT NULL,
  gross_amount NUMERIC(20,2),
  net_amount NUMERIC(20,2),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  recurring BOOLEAN NOT NULL DEFAULT false,
  source_transaction_id BIGINT REFERENCES finance.transactions(transaction_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (currency ~ '^[A-Z]{3}$'),
  CHECK (gross_amount IS NOT NULL OR net_amount IS NOT NULL)
);

CREATE TABLE finance.asset_snapshots (
  asset_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  owner_person_id BIGINT REFERENCES finance.persons(person_id) ON DELETE SET NULL,
  asset_type TEXT NOT NULL,
  asset_label TEXT NOT NULL,
  valued_at TIMESTAMPTZ NOT NULL,
  market_value NUMERIC(20,2) NOT NULL,
  liquid_value NUMERIC(20,2),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  import_batch_id BIGINT REFERENCES ingest.import_batches(import_batch_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, asset_label, valued_at),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE TABLE finance.liability_snapshots (
  liability_snapshot_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  owner_person_id BIGINT REFERENCES finance.persons(person_id) ON DELETE SET NULL,
  liability_type TEXT NOT NULL,
  liability_label TEXT NOT NULL,
  valued_at TIMESTAMPTZ NOT NULL,
  principal_balance NUMERIC(20,2) NOT NULL CHECK (principal_balance >= 0),
  monthly_payment NUMERIC(20,2),
  annual_interest_rate NUMERIC(8,5),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  import_batch_id BIGINT REFERENCES ingest.import_batches(import_batch_id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, liability_label, valued_at),
  CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE TABLE finance.recurring_obligations (
  recurring_obligation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  person_id BIGINT REFERENCES finance.persons(person_id) ON DELETE SET NULL,
  label TEXT NOT NULL,
  category TEXT NOT NULL,
  monthly_amount NUMERIC(20,2) NOT NULL CHECK (monthly_amount >= 0),
  currency CHAR(3) NOT NULL DEFAULT 'KRW',
  starts_on DATE,
  ends_on DATE,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (currency ~ '^[A-Z]{3}$'),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on)
);

CREATE TABLE planning.goals (
  goal_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  goal_type TEXT NOT NULL,
  label TEXT NOT NULL,
  target_amount NUMERIC(20,2),
  target_currency CHAR(3) DEFAULT 'KRW',
  target_date DATE,
  priority SMALLINT CHECK (priority BETWEEN 1 AND 5),
  notes TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (target_currency IS NULL OR target_currency ~ '^[A-Z]{3}$')
);

CREATE TABLE planning.career_scenarios (
  career_scenario_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  scenario_label TEXT NOT NULL,
  adult_role_label TEXT NOT NULL,
  annual_gross_income NUMERIC(20,2),
  annual_net_income NUMERIC(20,2),
  commute_minutes_one_way INTEGER CHECK (commute_minutes_one_way IS NULL OR commute_minutes_one_way >= 0),
  monthly_commute_cost NUMERIC(20,2) CHECK (monthly_commute_cost IS NULL OR monthly_commute_cost >= 0),
  work_days_per_week NUMERIC(3,1) CHECK (work_days_per_week IS NULL OR work_days_per_week BETWEEN 0 AND 7),
  assumptions JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, scenario_label, adult_role_label)
);

CREATE TABLE planning.housing_candidates (
  housing_candidate_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  candidate_label TEXT NOT NULL,
  housing_type TEXT NOT NULL,
  required_cash NUMERIC(20,2),
  purchase_price NUMERIC(20,2),
  deposit_amount NUMERIC(20,2),
  monthly_housing_cost NUMERIC(20,2),
  location_label TEXT,
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, candidate_label)
);

CREATE TABLE planning.childcare_constraints (
  childcare_constraint_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  household_id BIGINT NOT NULL REFERENCES finance.households(household_id) ON DELETE CASCADE,
  constraint_label TEXT NOT NULL,
  constraint_type TEXT NOT NULL,
  value_json JSONB NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (household_id, constraint_label)
);
