-- Run this once in psql after installing PostgreSQL and pgvector.
-- Creates the database schema for FOMC document chunks.
--
--   psql -U postgres -f setup_database.sql

CREATE DATABASE fomc_rag;
\c fomc_rag

-- Enable vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Main table. The starter repo used just a text column; we add metadata
-- so we can filter retrieval by date and document type.
CREATE TABLE fomc_chunks (
    id            SERIAL PRIMARY KEY,
    meeting_date  DATE NOT NULL,
    doc_type      TEXT NOT NULL CHECK (doc_type IN ('minutes', 'statement')),
    chunk_index   INT  NOT NULL,          -- position of chunk within document
    chunk_text    TEXT NOT NULL,
    embedding     vector(384)             -- all-MiniLM-L12-v2 outputs 384 dims
);

-- Index for fast cosine-distance search once the table is populated.
-- (Build AFTER bulk-loading data; it's faster that way.)
-- CREATE INDEX ON fomc_chunks USING hnsw (embedding vector_cosine_ops);

-- Table for the validation phase: LLM sentiment scores per meeting
CREATE TABLE meeting_sentiment (
    meeting_date     DATE PRIMARY KEY,
    hawkish_score    REAL,     -- -1 (very dovish) to +1 (very hawkish)
    next_rate_change REAL,     -- actual fed funds change at NEXT meeting, bps
    llm_rationale    TEXT
);
