%% STEP 3: Ask a question - retrieve relevant chunks, generate an answer
% Requires: "Large Language Models (LLMs) with MATLAB" add-on
%           (https://github.com/matlab-deep-learning/llms-with-matlab)
% Set your API key first, e.g.:  setenv("OPENAI_API_KEY", "sk-...")

clear; clc;

query = "What was the Committee's assessment of inflation risks in mid-2022?";

% Optional date filter - huge accuracy win over the naive starter repo.
% Leave empty ("") to search the whole corpus.
dateFilter = "AND meeting_date BETWEEN '2022-01-01' AND '2022-12-31'";

topK = 8;   % chunks to retrieve (starter repo used 30 - usually too many)

%% Embed the query with the SAME model used for the corpus
embeddingModel = documentEmbedding(Model="all-MiniLM-L12-v2");
qVec   = embed(embeddingModel, query);
qVecStr = "'[" + join(string(qVec), ",") + "]'";

%% Retrieve: cosine similarity search in pgvector
% <=> is pgvector's cosine DISTANCE operator, so similarity = 1 - distance.
conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);

sql = "SELECT meeting_date, chunk_text, " + ...
      "1 - (embedding <=> " + qVecStr + ") AS similarity " + ...
      "FROM fomc_chunks WHERE TRUE " + dateFilter + " " + ...
      "ORDER BY similarity DESC LIMIT " + topK;

hits = fetch(conn, sql);
close(conn);

fprintf("Top retrieved chunks:\n");
disp(hits(:, ["meeting_date", "similarity"]));

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
    "Question: " + query;

%% Generate the answer
answer = callClaude(systemPrompt, userPrompt);

fprintf("\n===== ANSWER =====\n%s\n", answer);
