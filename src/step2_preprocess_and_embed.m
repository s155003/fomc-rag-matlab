%% STEP 2: Extract text, chunk into paragraphs, embed, load into PostgreSQL
% Requires: Text Analytics Toolbox + all-MiniLM-L12-v2 support package
%           (install from Add-Ons menu), Database Toolbox, and a running
%           PostgreSQL instance with the schema from setup_database.sql.


rawDir = fullfile("..", "data", "raw");
files  = dir(fullfile(rawDir, "minutes_*.html"));
fprintf("Processing %d documents...\n", numel(files));

%% Load embedding model (384-dim output)
embeddingModel = documentEmbedding(Model="all-MiniLM-L12-v2");

%% Connect to PostgreSQL (native interface - no ODBC driver needed)
% Change credentials to match your local iconn = postgresql("postgres", "123Mrinalini!", ...nstall.
conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);

%% Process each document
for f = 1:numel(files)
    fpath = fullfile(files(f).folder, files(f).name);

    % Parse meeting date from filename: minutes_YYYYMMDD.html
    tok = regexp(files(f).name, 'minutes_(\d{8})', 'tokens', 'once');
    meetingDate = datetime(tok{1}, InputFormat="yyyyMMdd");

    % Skip if this meeting is already in the DB (makes script re-runnable)
    q = sprintf("SELECT COUNT(*) FROM fomc_chunks WHERE meeting_date='%s'", ...
        string(meetingDate, "yyyy-MM-dd"));
    if fetch(conn, q).count > 0, continue; end

    % --- Extract readable text from HTML ---
    raw = extractFileText(fpath);

    % --- Light cleanup ---
    % Strip boilerplate navigation junk and collapse whitespace.
    txt = regexprep(raw, '\r', '');
    txt = regexprep(txt, '[ \t]+', ' ');

    % --- Chunk by paragraph ---
    paras = strtrim(split(txt, [newline newline]));
    % Drop tiny fragments (nav links, page footers) and huge outliers
    paras = paras(strlength(paras) > 200 & strlength(paras) < 4000);
    fprintf("[%3d/%3d] %s -> %d chunks\n", f, numel(files), ...
        string(meetingDate, "yyyy-MM-dd"), numel(paras));

    if isempty(paras), continue; end

    % --- Embed all chunks at once ---
    E = embed(embeddingModel, paras);    % numel(paras) x 384 matrix

    % --- Insert into PostgreSQL ---
    for i = 1:numel(paras)
        vecStr  = "[" + join(string(E(i,:)), ",") + "]";
        insertQ = sprintf( ...
            "INSERT INTO fomc_chunks (meeting_date, doc_type, chunk_index, chunk_text, embedding) " + ...
            "VALUES ('%s', 'minutes', %d, $QUOTE$%s$QUOTE$, '%s')", ...
            string(meetingDate, "yyyy-MM-dd"), i, paras(i), vecStr);
        execute(conn, insertQ);
    end
end

%% Build the vector index now that data is loaded
execute(conn, "CREATE INDEX IF NOT EXISTS idx_fomc_hnsw ON fomc_chunks USING hnsw (embedding vector_cosine_ops)");

close(conn);
fprintf("Done. Corpus embedded and indexed.\n");
