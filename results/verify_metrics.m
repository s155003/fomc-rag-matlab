%% VERIFY_METRICS Recompute every reported metric from the committed CSV.
% Runs standalone: no PostgreSQL, no API keys, no pipeline re-run needed.
% A reviewer can execute this file from the results/ folder and compare
% the printed numbers against the README.

S = readtable("fomc_sentiment_scores.csv");
valid = ~isnan(S.next_change_bps);

rho = corr(S.hawkish_score(valid), S.next_change_bps(valid), Type="Spearman");

moved   = valid & S.next_change_bps ~= 0;
hitRate = mean(sign(S.hawkish_score(moved)) == sign(S.next_change_bps(moved)));

deadband  = 0.15;
actualCls = sign(S.next_change_bps(valid));
predCls   = sign(S.hawkish_score(valid));
predCls(abs(S.hawkish_score(valid)) <= deadband) = 0;
[C, order] = confusionmat(actualCls, predCls);

fprintf("Meetings evaluated:        %d\n", sum(valid));
fprintf("Spearman correlation:      %.3f\n", rho);
fprintf("Directional hit rate:      %.1f%% (n=%d moves)\n", 100*hitRate, sum(moved));
fprintf("3-class accuracy (db=%.2f): %.1f%%\n", deadband, 100*sum(diag(C))/sum(C,"all"));
fprintf("Models used: %s\n", strjoin(unique(string(S.model_id)), ", "));
fprintf("Confusion matrix (rows=actual, cols=predicted), classes %s:\n", mat2str(order'));
disp(C);
