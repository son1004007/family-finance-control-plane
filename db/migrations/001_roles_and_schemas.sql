-- Group roles are intentionally NOLOGIN. Runtime login roles are provisioned later
-- with secrets outside Git and granted membership in these roles.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_app') THEN
    CREATE ROLE finance_app NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ai_reader') THEN
    CREATE ROLE finance_ai_reader NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ai_writer') THEN
    CREATE ROLE finance_ai_writer NOLOGIN;
  END IF;
END
$$;

GRANT finance_ai_reader TO finance_ai_writer;

CREATE SCHEMA IF NOT EXISTS ingest;
CREATE SCHEMA IF NOT EXISTS finance;
CREATE SCHEMA IF NOT EXISTS planning;
CREATE SCHEMA IF NOT EXISTS analytics;

REVOKE ALL ON SCHEMA ingest, finance, planning, analytics FROM PUBLIC;

GRANT USAGE ON SCHEMA ingest, finance, planning TO finance_app;
GRANT USAGE ON SCHEMA finance, planning, analytics TO finance_ai_reader;
GRANT USAGE ON SCHEMA planning TO finance_ai_writer;

-- These defaults apply to objects created by the migration owner in later migrations.
ALTER DEFAULT PRIVILEGES IN SCHEMA ingest
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO finance_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA finance
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO finance_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA planning
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO finance_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA ingest, finance, planning
  GRANT USAGE, SELECT ON SEQUENCES TO finance_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA finance, planning, analytics
  GRANT SELECT ON TABLES TO finance_ai_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA planning
  GRANT INSERT, UPDATE, DELETE ON TABLES TO finance_ai_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA planning
  GRANT USAGE, SELECT ON SEQUENCES TO finance_ai_writer;
