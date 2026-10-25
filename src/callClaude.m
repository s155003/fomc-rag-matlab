function [txt, modelUsed] = callClaude(systemPrompt, userPrompt, opts)
%CALLCLAUDE Send a prompt to Anthropic's Claude API, return the text reply.
%   Requires environment variable ANTHROPIC_API_KEY to be set.
%
%   [txt, modelUsed] = callClaude(systemPrompt, userPrompt) uses the default
%   model at temperature 0 (deterministic output, so scores are reproducible).
%
%   Name-value options:
%     Model       - model ID string (default "claude-sonnet-4-6")
%     Temperature - sampling temperature (default 0)
%     MaxTokens   - response cap (default 1024)
%     MaxRetries  - retry attempts for transient errors (default 5)
%
%   Retries with exponential backoff on rate limits (429), overload (529)
%   and other transient failures; fails fast on auth/bad-request errors.

arguments
    systemPrompt (1,1) string
    userPrompt   (1,1) string
    opts.Model       (1,1) string = "claude-sonnet-4-6"
    opts.Temperature (1,1) double = 0
    opts.MaxTokens   (1,1) double = 1024
    opts.MaxRetries  (1,1) double = 5
end

apiKey = getenv("ANTHROPIC_API_KEY");
if isempty(apiKey)
    error("callClaude:noKey", ...
        "Set your key first: setenv('ANTHROPIC_API_KEY','sk-ant-...')");
end

body = struct( ...
    "model",       opts.Model, ...
    "max_tokens",  opts.MaxTokens, ...
    "temperature", opts.Temperature, ...
    "system",      systemPrompt, ...
    "messages",    {{struct("role","user","content",userPrompt)}});

wopts = weboptions( ...
    "MediaType", "application/json", ...
    "Timeout", 120, ...
    "HeaderFields", [ ...
        "x-api-key",         string(apiKey); ...
        "anthropic-version", "2023-06-01"]);

for attempt = 1:opts.MaxRetries
    try
        resp = webwrite("https://api.anthropic.com/v1/messages", body, wopts);
        break;
    catch err
        % Permanent client errors: do not retry
        if contains(err.message, ["400", "401", "403", "404"])
            rethrow(err);
        end
        if attempt == opts.MaxRetries
            rethrow(err);
        end
        wait = 2^attempt;   % 2, 4, 8, 16 s
        warning("callClaude:retry", "Attempt %d failed (%s). Retrying in %ds...", ...
            attempt, err.message, wait);
        pause(wait);
    end
end

% Response content is a list of blocks; concatenate the text ones
if iscell(resp.content)
    parts = cellfun(@(b) string(b.text), resp.content);
else
    parts = string(resp.content.text);
end
txt = join(parts, newline);
modelUsed = string(resp.model);   % exact model version the API served
end
