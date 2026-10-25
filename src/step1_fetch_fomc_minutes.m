%% STEP 1: Download FOMC meeting minutes from federalreserve.gov
% Minutes are published as HTML pages (and, for two meetings in the current
% range, PDF only: 2008-06-25 and 2012-10-23). Recent years live on the
% fomccalendars page; older years under /monetarypolicy/fomchistorical<year>.htm.
%
% Strategy: scrape the calendar/historical pages, extract minutes links in
% both HTML and PDF form, download each, and save into ../data/raw/.
% A per-year completeness report at the end makes missing meetings loud.

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

        % Minutes links come in three shapes:
        %   modern HTML:  .../fomcminutesYYYYMMDD.htm
        %   modern PDF:   .../fomcminutesYYYYMMDD.pdf  (only format for
        %                 2008-06-25 and 2012-10-23)
        %   pre-2008:     /fomc/minutes/YYYYMMDD.htm
        newStyle = regexp(html, ...
            'href="([^"]*fomcminutes\d{8}[^"]*\.(?:htm|pdf))"', 'tokens');
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

% If a meeting is available as both .htm and .pdf, keep only the .htm.
dateOf = @(s) regexp(s, '(?:fomcminutes|minutes/)(\d{8})', 'tokens', 'once');
dates8 = strings(numel(allLinks), 1);
for i = 1:numel(allLinks)
    t = dateOf(allLinks(i)); dates8(i) = t{1};
end
isPdf = endsWith(allLinks, ".pdf");
drop  = false(size(allLinks));
for i = 1:numel(allLinks)
    if isPdf(i) && any(dates8 == dates8(i) & ~isPdf)
        drop(i) = true;
    end
end
allLinks = allLinks(~drop); dates8 = dates8(~drop); isPdf = isPdf(~drop);

fprintf("Found %d minutes documents (%d html, %d pdf).\n", ...
    numel(allLinks), sum(~isPdf), sum(isPdf));

%% Download each document
for i = 1:numel(allLinks)
    link = allLinks(i);
    if ~startsWith(link, "http"), link = baseURL + link; end

    if isPdf(i), ext = ".pdf"; else, ext = ".html"; end
    dest = fullfile(outDir, "minutes_" + dates8(i) + ext);

    if isfile(dest), continue; end       % already downloaded, skip

    try
        websave(dest, link);
        fprintf("[%3d/%3d] saved minutes_%s%s\n", i, numel(allLinks), dates8(i), ext);
    catch err
        warning("step1:download", "Failed %s: %s", link, err.message);
    end

    pause(0.5);   % be polite to the Fed's servers
end

%% Completeness report: the FOMC holds 8 scheduled meetings per year.
% Fewer than 7 files for a completed year almost certainly means a
% missed format or a failed download - make that loud, not silent.
onDisk = [dir(fullfile(outDir, "minutes_*.html")); dir(fullfile(outDir, "minutes_*.pdf"))];
yrs = str2double(extractBetween(string({onDisk.name}'), 9, 12));   % minutes_YYYY...
counts = groupcounts(yrs);
uy = unique(yrs);
for k = 1:numel(uy)
    if uy(k) < year(datetime("today")) && counts(k) < 7
        warning("step1:incomplete", ...
            "Year %d has only %d minutes files - check for missed meetings.", ...
            uy(k), counts(k));
    end
end
fprintf("Done. %d documents on disk in %s\n", numel(onDisk), outDir);
