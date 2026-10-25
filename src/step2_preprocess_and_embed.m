%% STEP 2: Extract text, chunk into paragraphs, embed, load into PostgreSQL
% Requires: Text Analytics Toolbox + all-MiniLM-L12-v2 support package
%           (install from Add-Ons menu), Database Toolbox, and a running
%           PostgreSQL instance with the schema from sql/setup_database.sql.
% Credentials come from the FOMC_DB_PASSWORD environment variable; nothing
% is hardcoded here.
%
% Handles both the HTML minutes and the two PDF-only meetings; loads each
% document's chunks in a single batched insert via a staging table.

rawDir = fullfile("..", "data", "raw");
files  = [dir(fullfile(rawDir, "minutes_*.html")); dir(fullfile(rawDir, "minutes_*.pdf"))];
fprintf("Processing %d documents...\n", numel(files));

minChars = 200;    % drop nav fragments / footers below this
maxChars = 4000;   % split (not drop) paragraphs above this

%% Load embedding model (384-dim output)
embeddingModel = documentEmbedding(Model="all-MiniLM-L12-v2");

%% Connect to PostgreSQL (native interface - no ODBC driver needed)
conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);

% Dates already loaded (makes the script re-runnable)
doneT = fetch(conn, "SELECT DISTINCT meeting_date FROM fomc_chunks");
if isempty(doneT)
    doneDates = datetime.empty(0, 1);
else
    doneDates = doneT.meeting_date;
end

nLoaded = 0;
failedDocs = strings(0, 1);

%% Process each document
for f = 1:numel(files)
    fname = string(files(f).name);
    tok   = regexp(fname, 'minutes_(\d{8})\.(html|pdf)', 'tokens', 'once');
    meetingDate = datetime(tok{1}, InputFormat="yyyyMMdd");
    srcFormat   = replace(tok{2}, "html", "html");   % 'html' or 'pdf'

    if ismember(meetingDate, doneDates), continue; end

    try
        % --- Extract readable text (extractFileText reads HTML and PDF) ---
        raw = extractFileText(fullfile(files(f).folder, fname));
        txt = regexprep(raw, '\r', '');
        % PDFs hard-wrap lines mid-sentence: merge single newlines but keep
        % blank lines (paragraph boundaries) intact.
        txt = regexprep(txt, '(?<!\n)\n(?!\n)', ' ');
        txt = regexprep(txt, '[ \t]+', ' ');

        % --- Chunk by paragraph ---
        paras = strtrim(splitParagraphs(txt));
        paras = splitLongParagraphs(paras, maxChars);
        paras = paras(strlength(paras) > minChars);

        fprintf("[%3d/%3d] %s (%s) -> %d chunks\n", f, numel(files), ...
            string(meetingDate, "yyyy-MM-dd"), tok{2}, numel(paras));
        if isempty(paras)
            error("step2:empty", "no chunks extracted");
        end

        % --- Embed all chunks at once ---
        E = embed(embeddingModel, paras);    % numel(paras) x 384 matrix

        % --- One batched load per document via the staging table ---
        % (sqlwrite parameterizes values, so document text never gets
        % interpolated into a SQL string; %.8g keeps full single precision.)
        n = numel(paras);
        vecTxt = strings(n, 1);
        for i = 1:n
            vecTxt(i) = "[" + join(compose("%.8g", E(i, :)), ",") + "]";
        end
        T = table(repmat(meetingDate, n, 1), repmat(string(tok{2}), n, 1), ...
            int32((1:n)'), paras(:), vecTxt, VariableNames=[ ...
            "meeting_date", "source_format", "chunk_index", "chunk_text", "embedding_txt"]);

        execute(conn, "TRUNCATE fomc_chunks_staging");
        sqlwrite(conn, "fomc_chunks_staging", T);
        execute(conn, "INSERT INTO fomc_chunks " + ...
            "(meeting_date, source_format, chunk_index, chunk_text, embedding) " + ...
            "SELECT meeting_date, source_format, chunk_index, chunk_text, " + ...
            "embedding_txt::vector FROM fomc_chunks_staging");
        execute(conn, "TRUNCATE fomc_chunks_staging");
        nLoaded = nLoaded + 1;
    catch err
        failedDocs(end+1) = fname; %#ok<SAGROW>
        warning("step2:doc", "Skipped %s: %s", fname, err.message);
    end
end

%% Build the vector index now that data is loaded
execute(conn, "CREATE INDEX IF NOT EXISTS idx_fomc_hnsw ON fomc_chunks " + ...
    "USING hnsw (embedding vector_cosine_ops)");
execute(conn, "ANALYZE fomc_chunks");

total = fetch(conn, ...
    "SELECT COUNT(DISTINCT meeting_date) AS m, COUNT(*) AS c FROM fomc_chunks");
close(conn);

fprintf("Done. Loaded %d new documents. Corpus: %d meetings, %d chunks.\n", ...
    nLoaded, total.m, total.c);
if ~isempty(failedDocs)
    warning("step2:failed", "%d documents failed: %s", ...
        numel(failedDocs), join(failedDocs, ", "));
end

%% Local functions
function out = splitLongParagraphs(paras, maxChars)
% Split any paragraph longer than maxChars into sentence-aligned pieces
% (instead of silently dropping it, as the first version did).
out = strings(0, 1);
for p = 1:numel(paras)
    if strlength(paras(p)) <= maxChars
        out(end+1) = paras(p); %#ok<AGROW>
        continue;
    end
    sents = splitSentences(paras(p));
    buf = "";
    for s = 1:numel(sents)
        if strlength(buf) + strlength(sents(s)) + 1 > maxChars && buf ~= ""
            out(end+1) = strtrim(buf); %#ok<AGROW>
            buf = "";
        end
        buf = buf + " " + sents(s);
    end
    if strtrim(buf) ~= "", out(end+1) = strtrim(buf); end %#ok<AGROW>
end
out = out(:);
end
