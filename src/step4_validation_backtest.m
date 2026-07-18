%% STEP 4: Validation framework (the differentiator)
% For every meeting: have the LLM read the minutes and produce a
% hawkish/dovish score in [-1, +1]. Then test whether that score predicts
% the Fed's ACTUAL rate decision at the NEXT meeting.
%
% Hawkish (+) = leaning toward raising rates / fighting inflation
% Dovish  (-) = leaning toward cutting rates / supporting growth
%
% Ground truth: FRED series DFEDTARU (target rate upper bound) or the
% historical target rate. Download the CSV manually from
% https://fred.stlouisfed.org/series/DFEDTARU and place it in ../data/,
% or use the Datafeed Toolbox if you have it.


conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);

meetings = fetch(conn, ...
    "SELECT DISTINCT meeting_date FROM fomc_chunks ORDER BY meeting_date");
dates = meetings.meeting_date;
fprintf("Scoring %d meetings...\n", numel(dates));

%% 1) LLM sentiment scoring per meeting
scorePrompt = "You are a monetary policy analyst. Read these FOMC minutes " + ...
    "excerpts and output ONLY a JSON object: " + ...
    "{""hawkish_score"": <number from -1 to 1>, ""rationale"": ""<one sentence>""}. " + ...
    "+1 = strongly hawkish (bias toward tightening), -1 = strongly dovish.";

% Embed a policy probe once; used to pick the most policy-relevant
% chunks of each meeting instead of the first 25 (which in January
% meetings are just attendance lists and legal boilerplate).
embeddingModel = documentEmbedding(Model="all-MiniLM-L12-v2");
probe   = "inflation outlook, economic conditions, and the appropriate stance of monetary policy";
pVec    = embed(embeddingModel, probe);
pVecStr = "'[" + join(string(pVec), ",") + "]'";
for d = 1:numel(dates)
    % Skip meetings already scored (re-runnable)
    q = sprintf("SELECT COUNT(*) FROM meeting_sentiment WHERE meeting_date='%s'", ...
        string(dates(d), "yyyy-MM-dd"));
    if fetch(conn, q).count > 0, continue; end

    % Pull the policy-relevant chunks for this meeting. Rather than the
    % whole document, retrieve chunks most similar to a policy probe query.
    % (Reuses the RAG machinery from step 3 - see helper below.)
    chunks = fetch(conn, sprintf( ...
        "SELECT chunk_text FROM fomc_chunks WHERE meeting_date='%s' " + ...
        "ORDER BY embedding <=> " + pVecStr + " LIMIT 25", ...
        string(dates(d), "yyyy-MM-dd")));

    docText = join(chunks.chunk_text, newline);
    % Truncate to stay within context limits
    docText = extractBefore(docText + " ", min(strlength(docText)+1, 40000));

    try
        raw = callClaude(scorePrompt, docText);
        parsed = jsondecode(erase(raw, ["```json", "```"]));
        execute(conn, sprintf( ...
            "INSERT INTO meeting_sentiment (meeting_date, hawkish_score, llm_rationale) " + ...
            "VALUES ('%s', %f, $QUOTE$%s$QUOTE$)", ...
            string(dates(d), "yyyy-MM-dd"), parsed.hawkish_score, parsed.rationale));
        fprintf("[%3d/%3d] %s -> %+.2f\n", d, numel(dates), ...
            string(dates(d), "yyyy-MM-dd"), parsed.hawkish_score);
    catch err
        warning("Scoring failed for %s: %s", string(dates(d)), err.message);
    end
end

%% 2) Join with actual rate decisions
% Load FRED target-rate data and compute the change at each NEXT meeting.
% Stitch pre-2008 single target (DFEDTAR) with post-2008 upper bound (DFEDTARU)
ratesOld = readtable(fullfile("..", "data", "DFEDTAR.csv"));
ratesOld.Properties.VariableNames = ["date", "rate"];
ratesNew = readtable(fullfile("..", "data", "DFEDTARU.csv"));
ratesNew.Properties.VariableNames = ["date", "rate"];
rates = [ratesOld; ratesNew];   % TAR ends 2008-12-15, TARU starts 2008-12-16
rates = sortrows(rates, "date");

sent = fetch(conn, "SELECT meeting_date, hawkish_score FROM meeting_sentiment ORDER BY meeting_date");

nextChange = nan(height(sent), 1);
for i = 1:height(sent) - 1
    thisMeeting = sent.meeting_date(i);
    nextMeeting = sent.meeting_date(i + 1);
    rBefore = rates.rate(find(rates.date <= nextMeeting - 1, 1, "last"));
    rAfter  = rates.rate(find(rates.date >= nextMeeting + 2, 1, "first"));
    if ~isempty(rBefore) && ~isempty(rAfter)
        nextChange(i) = (rAfter - rBefore) * 100;   % basis points
    end
end
sent.next_change_bps = nextChange;

%% 3) Evaluate: does sentiment predict the next move?
valid = ~isnan(sent.next_change_bps);
rho = corr(sent.hawkish_score(valid), sent.next_change_bps(valid), ...
    Type="Spearman");

% Directional hit rate on meetings where a move actually happened
moved   = valid & sent.next_change_bps ~= 0;
hits    = sign(sent.hawkish_score(moved)) == sign(sent.next_change_bps(moved));
hitRate = mean(hits);

fprintf("\n===== VALIDATION RESULTS =====\n");
fprintf("Meetings evaluated:      %d\n", sum(valid));
fprintf("Spearman correlation:    %.3f\n", rho);
fprintf("Directional hit rate:    %.1f%% (n=%d moves)\n", 100*hitRate, sum(moved));

%% 4) Plot: sentiment vs subsequent policy action
figure;
yyaxis left
plot(sent.meeting_date, sent.hawkish_score, "-o"); ylabel("Hawkish score");
yyaxis right
stem(sent.meeting_date, sent.next_change_bps); ylabel("Next-meeting change (bps)");
title("LLM-extracted FOMC sentiment vs actual policy moves");
grid on;

close(conn);
