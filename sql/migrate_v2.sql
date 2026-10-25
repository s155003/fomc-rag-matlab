-- Migration for databases created with the original (v1) schema.
-- Run once:  psql -h localhost -U postgres -d fomc_rag -f sql/migrate_v2.sql
--
-- 1. doc_type -> source_format (statements were never ingested; the
--    column now records which file format a chunk was extracted from)
ALTER TABLE fomc_chunks RENAME COLUMN doc_type TO source_format;
ALTER TABLE fomc_chunks DROP CONSTRAINT IF EXISTS fomc_chunks_doc_type_check;
UPDATE fomc_chunks SET source_format = 'html';
ALTER TABLE fomc_chunks
    ADD CONSTRAINT fomc_chunks_source_format_check
    CHECK (source_format IN ('html', 'pdf'));

-- 2. Record the serving model per score
ALTER TABLE meeting_sentiment ADD COLUMN IF NOT EXISTS model_id TEXT;

-- 3. Staging table for batched chunk loads
CREATE TABLE IF NOT EXISTS fomc_chunks_staging (
    meeting_date  DATE,
    source_format TEXT,
    chunk_index   INT,
    chunk_text    TEXT,
    embedding_txt TEXT
);

-- 4. Old scores were produced at default temperature and are not
--    reproducible; clear them so step4 rescores everything at
--    temperature 0 with the model recorded.
TRUNCATE meeting_sentiment;
