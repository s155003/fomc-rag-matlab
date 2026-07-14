function txt = callClaude(systemPrompt, userPrompt)
%CALLCLAUDE Send a prompt to Anthropic's Claude API, return the text reply.
%   Requires environment variable ANTHROPIC_API_KEY to be set.

apiKey = getenv("ANTHROPIC_API_KEY");
if isempty(apiKey)
    error("Set your key first: setenv('ANTHROPIC_API_KEY','sk-ant-...')");
end

body = struct( ...
    "model", "claude-sonnet-4-6", ...
    "max_tokens", 1024, ...
    "system", systemPrompt, ...
    "messages", {{struct("role","user","content",userPrompt)}});

opts = weboptions( ...
    "MediaType", "application/json", ...
    "Timeout", 60, ...
    "HeaderFields", [ ...
    "x-api-key",         string(apiKey); ...
    "anthropic-version", "2023-06-01"]);

resp = webwrite("https://api.anthropic.com/v1/messages", body, opts);

% Response content is a list of blocks; concatenate the text ones
if iscell(resp.content)
    parts = cellfun(@(b) string(b.text), resp.content);
else
    parts = string(resp.content.text);
end
txt = join(parts, newline);
end