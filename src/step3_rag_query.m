%% STEP 3: Ask a question - retrieve relevant chunks, generate an answer
% Requires: callClaude.m (custom Anthropic Messages API client) and the
% ANTHROPIC_API_KEY environment variable; database access via the
% FOMC_DB_PASSWORD environment variable. No other add-ons needed.
%
% Edit the variables below, or launch fomcApp for an interactive version.

queryText = "What was the Committee's assessment of inflation risks in mid-2022?";

% Date range to search: [] for the whole corpus, or [from, to] datetimes.
dateRange = [datetime(2022,1,1), datetime(2022,12,31)];

topK = 8;   % chunks to retrieve

%% Retrieve + generate (shared with the app - see ragAnswer.m)
[answer, hits] = ragAnswer(queryText, dateRange, topK);

fprintf("Top retrieved chunks:\n");
disp(hits(:, ["meeting_date", "similarity"]));
fprintf("\n===== ANSWER =====\n%s\n", answer);
