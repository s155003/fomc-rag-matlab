%% STEP 4: Validation framework (the differentiator)
% For every meeting: have the LLM read the minutes and produce a
% hawkish/dovish score in [-1, +1]. Then test whether that score predicts
% the Fed's ACTUAL rate decision at the NEXT meeting.
%
% Hawkish (+) = leaning toward raising rates / fighting inflation
% Dovish  (-) = leaning toward cutting rates / supporting growth
%
% Ground truth: FRED series DFEDTAR (through 2008-12-15) stitched with
% DFEDTARU (from 2008-12-16). Download both CSVs into ../data/ - see README.
%
% Scoring runs at temperature 0 with the exact serving model recorded per
% score, so the headline metrics are reproducible. Results are exported to
% ../results/fomc_sentiment_scores.csv; ../results/verify_metrics.m
% recomputes every reported number from that file alone.

conn = postgresql("postgres", getenv("FOMC_DB_PASSWORD"), ...
    DatabaseName="fomc_rag", Server="localhost", PortNumber=5432);

% The FULL meeting calendar from the corpus. All pairing below uses this
% calendar, never adjacency in meeting_sentiment, so a missing score can
% not silently shift which rate decision a score is compared against.
calT = fetch(conn, ...
    "SELECT DISTINCT meeting_date FROM fomc_chunks ORDER BY meeting_date");
calendar = calT.meeting_date;
fprintf("Corpus calendar: %d meetings.\n", numel(calendar));

%% 1) LLM sentiment scoring per meeting (temperature 0, model recorded)
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
pVecStr = "'[" + join(compose("%.8g", pVec), ",") + "]'";

scoredT = fetch(conn, "SELECT meeting_date FROM meeting_sentiment");
if isempty(scoredT)
    alreadyScored = datetime.empty(0, 1);
else
    alreadyScored = scoredT.meeting_date;
end

for d = 1:numel(calendar)
    if ismember(calendar(d), alreadyScored), continue; end   % re-runnable

    % Most policy-relevant chunks for this meeting (ordered by the HNSW
    % distance operator so the index is used).
    chunks = fetch(conn, sprintf( ...
        "SELECT chunk_text FROM fomc_chunks WHERE meeting_date='%s' " + ...
        "ORDER BY embedding <=> " + pVecStr + " LIMIT 25", ...
        string(calendar(d), "yyyy-MM-dd")));

    docText = join(chunks.chunk_text, newline);
    docText = extractBefore(docText + " ", min(strlength(docText)+1, 40000));

    try
        [raw, modelUsed] = callClaude(scorePrompt, docText);
        parsed = jsondecode(erase(raw, ["```json", "```"]));
        % sqlwrite parameterizes values - LLM text never enters a SQL string
        T = table(calendar(d), parsed.hawkish_score, modelUsed, ...
            string(parsed.rationale), VariableNames=[ ...
            "meeting_date", "hawkish_score", "model_id", "llm_rationale"]);
        sqlwrite(conn, "meeting_sentiment", T);
        fprintf("[%3d/%3d] %s -> %+.2f (%s)\n", d, numel(calendar), ...
            string(calendar(d), "yyyy-MM-dd"), parsed.hawkish_score, modelUsed);
    catch err
        warning("step4:score", "Scoring failed for %s: %s", ...
            string(calendar(d)), err.message);
    end
end

%% 2) Join with actual rate decisions
% Stitch pre-2008 single target (DFEDTAR) with post-2008 upper bound (DFEDTARU)
rates = loadRateSeries(fullfile("..", "data"));

sent = fetch(conn, ...
    "SELECT meeting_date, hawkish_score, model_id, llm_rationale " + ...
    "FROM meeting_sentiment ORDER BY meeting_date");

% Pair each CALENDAR meeting's score with the rate change at the NEXT
% CALENDAR meeting. Track and report every exclusion.
nextChange = nan(height(sent), 1);
nUnscoredPair = 0; nNoRate = 0;
scoreMap = dictionary(string(sent.meeting_date, "yyyy-MM-dd"), (1:height(sent))');

for i = 1:numel(calendar) - 1
    key = string(calendar(i), "yyyy-MM-dd");
    if ~isKey(scoreMap, key)
        nUnscoredPair = nUnscoredPair + 1;   % this meeting has no score
        continue;
    end
    row = scoreMap(key);
    nextMeeting = calendar(i + 1);
    rBefore = rates.rate(find(rates.date <= nextMeeting - 1, 1, "last"));
    rAfter  = rates.rate(find(rates.date >= nextMeeting + 2, 1, "first"));
    if isempty(rBefore) || isempty(rAfter)
        nNoRate = nNoRate + 1;
        continue;
    end
    nextChange(row) = (rAfter - rBefore) * 100;   % basis points
end
sent.next_change_bps = nextChange;

fprintf("Pairing: %d calendar meetings, %d scored, %d unscored, " + ...
    "%d lacked rate data, last meeting has no successor.\n", ...
    numel(calendar), height(sent), nUnscoredPair, nNoRate);

% Persist the pairing into the column declared for it
for i = 1:height(sent)
    if ~isnan(sent.next_change_bps(i))
        execute(conn, sprintf( ...
            "UPDATE meeting_sentiment SET next_rate_change=%.4f WHERE meeting_date='%s'", ...
            sent.next_change_bps(i), string(sent.meeting_date(i), "yyyy-MM-dd")));
    end
end
close(conn);

%% 3) Export results so metrics are verifiable without the DB or API
resultsDir = fullfile("..", "results");
if ~isfolder(resultsDir), mkdir(resultsDir); end
writetable(sent, fullfile(resultsDir, "fomc_sentiment_scores.csv"));
fprintf("Scores exported to results/fomc_sentiment_scores.csv\n");

%% 4) Evaluate (same computations as results/verify_metrics.m)
valid = ~isnan(sent.next_change_bps);
rho = corr(sent.hawkish_score(valid), sent.next_change_bps(valid), ...
    Type="Spearman");

moved   = valid & sent.next_change_bps ~= 0;
hitsOk  = sign(sent.hawkish_score(moved)) == sign(sent.next_change_bps(moved));
hitRate = mean(hitsOk);

% Cut/hold/hike confusion matrix (deadband of +/-0.15 maps a near-zero
% score to a predicted hold) and a naive persistence baseline.
deadband  = 0.15;
actualCls = sign(sent.next_change_bps(valid));
predCls   = sign(sent.hawkish_score(valid));
predCls(abs(sent.hawkish_score(valid)) <= deadband) = 0;
[C, order] = confusionmat(actualCls, predCls);

lastMove = naivePersistenceBaseline(sent.meeting_date(valid), rates);
baseOk   = lastMove(actualCls ~= 0) == actualCls(actualCls ~= 0);

fprintf("\n===== VALIDATION RESULTS =====\n");
fprintf("Meetings evaluated:        %d\n", sum(valid));
fprintf("Spearman correlation:      %.3f\n", rho);
fprintf("Directional hit rate:      %.1f%% (n=%d moves)\n", 100*hitRate, sum(moved));
fprintf("3-class accuracy (db=%.2f): %.1f%%\n", deadband, 100*sum(diag(C))/sum(C, "all"));
fprintf("Naive last-move baseline:  %.1f%% directional on moves\n", 100*mean(baseOk));
fprintf("Confusion matrix (rows=actual, cols=predicted), classes %s:\n", mat2str(order'));
disp(C);

%% 5) Plot: sentiment vs subsequent policy action
figure;
yyaxis left
plot(sent.meeting_date, sent.hawkish_score, "-o"); ylabel("Hawkish score");
yyaxis right
stem(sent.meeting_date, sent.next_change_bps); ylabel("Next-meeting change (bps)");
title("LLM-extracted FOMC sentiment vs actual policy moves");
grid on;

%% Local functions
function rates = loadRateSeries(dataDir)
% Robust FRED CSV import: detect options instead of assuming layout.
optsOld = detectImportOptions(fullfile(dataDir, "DFEDTAR.csv"));
optsNew = detectImportOptions(fullfile(dataDir, "DFEDTARU.csv"));
ratesOld = readtable(fullfile(dataDir, "DFEDTAR.csv"), optsOld);
ratesNew = readtable(fullfile(dataDir, "DFEDTARU.csv"), optsNew);
ratesOld.Properties.VariableNames = ["date", "rate"];
ratesNew.Properties.VariableNames = ["date", "rate"];
rates = sortrows([ratesOld; ratesNew], "date");   % TAR ends 2008-12-15
rates = rates(~isnan(rates.rate), :);
end

function lastMove = naivePersistenceBaseline(dates, rates)
% Baseline: predict the same direction as the most recent ACTUAL move
% before each meeting.
lastMove = zeros(numel(dates), 1);
dr = diff(rates.rate);
chgIdx = find(dr ~= 0);
for i = 1:numel(dates)
    prior = chgIdx(rates.date(chgIdx) < dates(i));
    if ~isempty(prior)
        lastMove(i) = sign(dr(prior(end)));
    end
end
end
