function fomcApp
%FOMCAPP Interactive explorer for the FOMC minutes RAG system.
%   Type a question, pick a date range and Top-K, press Ask. Retrieved
%   chunks appear in the table with their similarity; the grounded,
%   citation-bearing answer appears below. Built on the same ragAnswer
%   function the scripted pipeline uses.
%
%   Requires env vars FOMC_DB_PASSWORD and ANTHROPIC_API_KEY (see README).

fig = uifigure(Name="FOMC Minutes Explorer", Position=[100 100 860 600]);
gl = uigridlayout(fig, [5 6]);
gl.RowHeight   = {30, 30, 180, 22, '1x'};
gl.ColumnWidth = {90, '1x', 90, 130, 90, 100};

% Row 1: question
lblQ = uilabel(gl, Text="Question:");
lblQ.Layout.Row = 1; lblQ.Layout.Column = 1;
efQ = uieditfield(gl, "text", ...
    Value="What was the Committee's assessment of inflation risks in mid-2022?");
efQ.Layout.Row = 1; efQ.Layout.Column = [2 6];

% Row 2: date range, top-k, ask
lblF = uilabel(gl, Text="From:");
lblF.Layout.Row = 2; lblF.Layout.Column = 1;
dpFrom = uidatepicker(gl, Value=datetime(2000,1,1));
dpFrom.Layout.Row = 2; dpFrom.Layout.Column = 2;
lblT = uilabel(gl, Text="To:");
lblT.Layout.Row = 2; lblT.Layout.Column = 3;
dpTo = uidatepicker(gl, Value=datetime("today"));
dpTo.Layout.Row = 2; dpTo.Layout.Column = 4;
spK = uispinner(gl, Limits=[1 30], Value=8);
spK.Layout.Row = 2; spK.Layout.Column = 5;
btn = uibutton(gl, Text="Ask", ButtonPushedFcn=@onAsk);
btn.Layout.Row = 2; btn.Layout.Column = 6;

% Row 3: retrieved chunks
tbl = uitable(gl, ColumnName=["Meeting", "Similarity", "Excerpt"]);
tbl.Layout.Row = 3; tbl.Layout.Column = [1 6];

% Rows 4-5: answer
lblA = uilabel(gl, Text="Answer:");
lblA.Layout.Row = 4; lblA.Layout.Column = [1 6];
ta = uitextarea(gl, Editable="off", Value="");
ta.Layout.Row = 5; ta.Layout.Column = [1 6];

    function onAsk(~, ~)
        btn.Enable = "off"; btn.Text = "Working...";
        ta.Value = "Retrieving and generating...";
        drawnow;
        try
            [answerText, hits] = ragAnswer(string(efQ.Value), ...
                [dpFrom.Value, dpTo.Value], spK.Value);
            preview = extractBefore(hits.chunk_text + " ", ...
                min(strlength(hits.chunk_text) + 1, 120));
            tbl.Data = table(string(hits.meeting_date), ...
                round(hits.similarity, 3), preview);
            ta.Value = splitlines(answerText);
        catch err
            ta.Value = "Error: " + err.message;
        end
        btn.Enable = "on"; btn.Text = "Ask";
    end
end
