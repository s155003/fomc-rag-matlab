%% STEP 1: Download FOMC meeting minutes from federalreserve.gov
% Minutes from ~1993 onward are published as HTML pages with predictable
% URLs. Recent years (2021+) also live on the fomccalendars page; older
% years are under /monetarypolicy/fomchistorical<year>.htm.
%
% Strategy: scrape the calendar/historical pages, extract links containing
% "fomcminutes", download each, and save raw HTML into ../data/raw/.

clear; clc;

outDir = fullfile("..", "data", "raw");
if ~isfolder(outDir), mkdir(outDir); end

baseURL   = "https://www.federalreserve.gov";
startYear = 2000;                      % adjust range as desired
endYear   = year(datetime("today"));

allLinks = strings(0, 1);

for y = startYear:endYear
    % Recent ~5 years are on the main calendar page; older years have
    % dedicated historical pages. Try historical first, fall back.
    candidates = [ ...
        baseURL + "/monetarypolicy/fomchistorical" + y + ".htm", ...
        baseURL + "/monetarypolicy/fomccalendars.htm" ];

    for c = candidates
        try
            html = webread(c);
        catch
            continue;   % page doesn't exist for this year, skip
        end

        % Pull every href that looks like a minutes page for year y
        % (two URL formats: modern "fomcminutesYYYYMMDD.htm" and
        %  pre-2008 "/fomc/minutes/YYYYMMDD.htm")
        newStyle = regexp(html, ...
            'href="([^"]*fomcminutes\d{8}[^"]*\.htm)"', 'tokens');
        oldStyle = regexp(html, ...
            'href="([^"]*/fomc/minutes/\d{8}\.htm)"', 'tokens');
        links = string([[newStyle{:}], [oldStyle{:}]]');

        % Keep only links dated this year
        links = links(contains(links, "fomcminutes" + y) | ...
                      contains(links, "minutes/" + y));
        allLinks = [allLinks; links]; %#ok<AGROW>

        if ~isempty(links), break; end   % found them, no need for fallback
    end
end

allLinks = unique(allLinks);
fprintf("Found %d minutes documents.\n", numel(allLinks));

%% Download each document
for i = 1:numel(allLinks)
    link = allLinks(i);
    if ~startsWith(link, "http"), link = baseURL + link; end

    % Extract the yyyymmdd date from the filename for naming
    tok  = regexp(link, '(?:fomcminutes|minutes/)(\d{8})', 'tokens', 'once');
    name = "minutes_" + tok{1} + ".html";
    dest = fullfile(outDir, name);

    if isfile(dest), continue; end       % already downloaded, skip

    try
        websave(dest, link);
        fprintf("[%3d/%3d] saved %s\n", i, numel(allLinks), name);
    catch err
        warning("Failed %s: %s", link, err.message);
    end

    pause(0.5);   % be polite to the Fed's servers
end

fprintf("Done. Raw HTML in %s\n", outDir);
