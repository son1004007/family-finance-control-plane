BEGIN;

ALTER TABLE ingest.import_batches
  ADD COLUMN IF NOT EXISTS mapping_sha256 CHAR(64),
  ADD COLUMN IF NOT EXISTS normalizer_version TEXT;

ALTER TABLE ingest.import_batches
  DROP CONSTRAINT IF EXISTS import_batches_file_sha256_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_import_batches_source_file_mapping
  ON ingest.import_batches(
    source_type,
    source_name,
    file_sha256,
    COALESCE(mapping_sha256, repeat('0', 64))
  );

COMMIT;
