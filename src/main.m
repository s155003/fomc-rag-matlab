%% FOMC Minutes Analysis with LLMs - Main Entry Point
% Runs the full pipeline end-to-end. Each stage is skippable via the
% flags below. Every stage script also self-skips completed work, so
% re-running is cheap and safe.
%
% Prerequisites (see README):
%   - PostgreSQL running with the fomc_rag database (sql/setup_database.sql)
%   - FRED CSVs (DFEDTAR.csv, DFEDTARU.csv) in ../data/
%   - Environment variables set for this session:
%       setenv("FOMC_DB_PASSWORD", "...")
%       setenv("ANTHROPIC_API_KEY", "sk-ant-...")

%% Configuration
RUN_SCRAPER   = true;   % step 1: download FOMC minutes (~5 min first run)
RUN_EMBEDDING = true;   % step 2: chunk + embed + load into pgvector (~20 min first run)
RUN_RAG_DEMO  = true;   % step 3: answer a sample question (1 LLM call)
RUN_BACKTEST  = true;   % step 4: sentiment backtest (~210 LLM calls first run)

%% Preflight checks
assert(~isempty(getenv("FOMC_DB_PASSWORD")), ...
    "Set the database password first: setenv('FOMC_DB_PASSWORD', '...')");
assert(~isempty(getenv("ANTHROPIC_API_KEY")), ...
    "Set the API key first: setenv('ANTHROPIC_API_KEY', 'sk-ant-...')");

%% Pipeline
if RUN_SCRAPER,   step1_fetch_fomc_minutes;    end
if RUN_EMBEDDING, step2_preprocess_and_embed;  end
if RUN_RAG_DEMO,  step3_rag_query;             end
if RUN_BACKTEST,  step4_validation_backtest;   end

fprintf("\nPipeline complete.\n");