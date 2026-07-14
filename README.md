# FOMC Minutes Analysis with LLMs (MathWorks Challenge Project #258)

MATLAB RAG pipeline over Federal Reserve FOMC meeting minutes, plus a
validation framework that backtests LLM-extracted policy sentiment against
actual rate decisions.

## Architecture

```
Fed website ──► step1 scraper ──► raw HTML
                                    │
                    step2: extract, chunk, embed (all-MiniLM-L12-v2)
                                    │
                          PostgreSQL + pgvector
                                    │
              step3: query ──► cosine retrieval ──► LLM answer
                                    │
              step4: sentiment scoring ──► backtest vs FRED rate data
```

## Setup (one time)

1. **MATLAB toolboxes**: Text Analytics, Database, Statistics & ML, Deep
   Learning. Add-ons: *Text Analytics Toolbox Model for all-MiniLM-L12-v2*
   and *Large Language Models (LLMs) with MATLAB*.
2. **PostgreSQL**: install from postgresql.org, then install
   [pgvector](https://github.com/pgvector/pgvector)
   (Windows: easiest via the prebuilt installer or WSL; Mac: `brew install pgvector`).
3. **Schema**: `psql -U postgres -f sql/setup_database.sql`
4. **API key**: `setenv("OPENAI_API_KEY", "...")` in MATLAB (or configure
   another provider supported by llms-with-matlab).
5. **Rate data** (for step 4): download DFEDTARU.csv from
   https://fred.stlouisfed.org/series/DFEDTARU into `data/`.

## Run order

| Script | What it does | Runtime |
|---|---|---|
| `src/step1_fetch_fomc_minutes.m` | Scrapes ~200 minutes docs (2000-present) | ~5 min |
| `src/step2_preprocess_and_embed.m` | Chunk + embed + load into pgvector | ~15 min |
| `src/step3_rag_query.m` | Ask a question, get a cited answer | seconds |
| `src/step4_validation_backtest.m` | Sentiment backtest vs real rate moves | ~30 min (LLM calls) |

All scripts are re-runnable; they skip work already done.

## Edit before running

- Database password in steps 2-4 (`YOUR_PASSWORD_HERE`)
- Year range in step 1 if you want a different corpus
- LLM model name in steps 3-4 if not using OpenAI
