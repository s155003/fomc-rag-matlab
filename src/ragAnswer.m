function [answerText, hits] = ragAnswer(queryText, dateRange, topK)
%RAGANSWER Retrieve relevant FOMC chunks and generate a grounded answer.
%   [answerText, hits] = ragAnswer(queryText, dateRange, topK)
%
%   queryText - natural-language question (string)
%   dateRange - [] for the whole corpus, or a 1x2 datetime [from, to]
%   topK      - number of chunks to retrieve (default 8)
%
%   Requires env vars FOMC_DB_PASSWORD and ANTHROPIC_API_KEY.
%   Used by step3_rag_query.m and the fomcApp interactive app.

arguments
    queryText (1,1) string
    dateRange = []
    topK (1,1) double = 8
end

%% Embed the query with the SAME model used for the corpus
embeddingModel = documentEmbedding(Model="all-MiniLM-L12-v2");
qVec    = embed(embeddingModel, queryText);
qVecStr = "'[" + join(compose("%.8g", qVec), ",") + "]'";

%% Retrieve: cosine similarity search in pgvector
% <=> is pgvector's cosine DISTANCE operator. Ordering directly by
% embedding <=> query (not by a derived alias) lets PostgreSQL use the
% HNSW index; similarity is returned as a computed column instead.
dateFilter = "";
if ~isempty(dateRange)
    dateFilter = sprintf("AND meeting_date BETWEEN '%s' AND '%s' ", ...
        string(dateRange(1), "yyyy-MM-dd"), string(dateRange(2), "yyyy-MM-dd"));
end

conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);
sql = "SELECT meeting_date, chunk_text, " + ...
      "1 - (embedding <=> " + qVecStr + ") AS similarity " + ...
      "FROM fomc_chunks WHERE TRUE " + dateFilter + ...
      "ORDER BY embedding <=> " + qVecStr + " LIMIT " + topK;
hits = fetch(conn, sql);
close(conn);

if isempty(hits)
    answerText = "No matching excerpts found for that date range.";
    return;
end

%% Build the prompt: retrieved context + question
contextBlocks = strings(height(hits), 1);
for i = 1:height(hits)
    contextBlocks(i) = "[Meeting " + string(hits.meeting_date(i)) + "] " ...
        + hits.chunk_text(i);
end
context = join(contextBlocks, [newline newline]);

systemPrompt = "You are a monetary policy analyst. Answer the question " + ...
    "using ONLY the provided FOMC minutes excerpts. Cite the meeting " + ...
    "date for every claim. If the excerpts don't contain the answer, say so.";
userPrompt = "Excerpts:" + newline + context + newline + newline + ...
    "Question: " + queryText;

answerText = callClaude(systemPrompt, userPrompt);
end
