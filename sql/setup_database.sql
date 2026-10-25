-- Run this once in psql after installing PostgreSQL and pgvector.
-- Creates the database schema for FOMC document chunks.
--
--   psql -U postgres -f setup_database.sql

CREATE DATABASE fomc_rag;
\c fomc_rag

-- Enable vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Main table: one row per text chunk, with metadata for date-filtered
-- retrieval and the source format it was extracted from.
CREATE TABLE fomc_chunks (
    id            SERIAL PRIMARY KEY,
    meeting_date  DATE NOT NULL,
    source_format TEXT NOT NULL CHECK (source_format IN ('html', 'pdf')),
    chunk_index   INT  NOT NULL,          -- position of chunk within document
    chunk_text    TEXT NOT NULL,
    embedding     vector(384)             -- all-MiniLM-L12-v2 outputs 384 dims
);

-- Staging table for batched loads: step2 writes each document's chunks
-- here with sqlwrite (parameterized), then INSERT..SELECTs them across
-- with an embedding_txt::vector cast in one statement.
CREATE TABLE fomc_chunks_staging (
    meeting_date  DATE,
    source_format TEXT,
    chunk_index   INT,
    chunk_text    TEXT,
    embedding_txt TEXT
);

-- Index for fast cosine-distance search once the table is populated.
-- (step2 builds it after bulk-loading; it's faster that way.)
-- CREATE INDEX ON fomc_chunks USING hnsw (embedding vector_cosine_ops);

-- Validation phase: LLM sentiment scores per meeting, the serving model
-- that produced each score, and the next meeting's actual rate change.
CREATE TABLE meeting_sentiment (
    meeting_date     DATE PRIMARY KEY,
    hawkish_score    REAL,     -- -1 (very dovish) to +1 (very hawkish)
    next_rate_change REAL,     -- actual fed funds change at NEXT meeting, bps
    model_id         TEXT,     -- exact model version that produced the score
    llm_rationale    TEXT
);
