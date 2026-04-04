function resultsTable = captureSlideList(cfg, client, slideList, startSampleId)
%CAPTURESLIDELIST Batch capture a list of slides with retry and checkpoints.
%
% Features:
%   - Create one rx per slide
%   - Reuse rx across attempts of the same slide
%   - Recreate rx on exception
%   - Recreate rx after repeated ordinary FAILs
%   - Special handling for:
%       1) common first-attempt transient failures
%       2) hard formal failures (all formal frames invalid)
%   - Progress bar / ETA
%   - Final CSV merge from:
%       * current-run rows
%       * existing capture_log.csv in output dir
%       * all checkpoint CSVs in checkpoints folder

    arguments
        cfg struct
        client
        slideList
        startSampleId (1,1) double = 1
    end

    if ~exist(cfg.general.out_dir, 'dir')
        mkdir(cfg.general.out_dir);
    end

    if ~exist(cfg.general.checkpoint_dir, 'dir')
        mkdir(cfg.general.checkpoint_dir);
    end

    n = numel(slideList);
    results = repmat(makeEmptyResultRow(), n, 1);

    t_batch = tic;

    fprintf('========================================\n');
    fprintf('Batch capture started.\n');
    fprintf('Total slides: %d\n', n);
    fprintf('Output dir : %s\n', cfg.general.out_dir);
    fprintf('Checkpoint : every %d slide(s)\n', cfg.general.checkpoint_every);
    fprintf('Pause between attempts: %.3f s\n', cfg.general.pause_between_attempts_s);
    fprintf('Starting sample_id: %d\n', startSampleId);
    fprintf('========================================\n');

    for k = 1:n
        t_item = tic;

        slideMeta = slideList(k);
        sample_id = startSampleId + k - 1;

        fprintf('\n----------------------------------------\n');
        fprintf('Item %03d / %03d | sample %03d | slide %03d\n', ...
            k, n, sample_id, slideMeta.slide_index);

        success = false;
        lastErrMsg = "";
        ordinaryFailCount = 0;
        rx = [];

        try
            fprintf('Creating rx for slide %d ...\n', slideMeta.slide_index);
            rx = x310CreateRx(cfg);

            if isfield(cfg, 'sdr') && isfield(cfg.sdr, 'pause_after_rx_create_s')
                if cfg.sdr.pause_after_rx_create_s > 0
                    pause(cfg.sdr.pause_after_rx_create_s);
                end
            end

            for attempt = 1:(cfg.general.retry_max + 1)
                try
                    fprintf('Attempt %d ...\n', attempt);

                    r = captureOneSlide(cfg, client, rx, slideMeta, sample_id, attempt);

                    if r.ok
                        status = "PASS";
                        if attempt > 1
                            status = "RETRY_PASS";
                        end
                        success = true;
                    else
                        status = "FAIL";
                    end

                    results(k) = buildResultRow(r, status, attempt - 1);

                    if success
                        fprintf('PASS: %s\n', r.filename);
                        break;
                    end

                    fprintf(['FAIL details: use_warmup=%d, warmup_run=%g, use_prime=%d, prime_run=%g, ', ...
                             'stage=%s, msg=%s, warmup_ov=%g, total_ov=%g, warmup_bad_len=%g, ', ...
                             'bad_len=%g, received=%g, theoretical=%g\n'], ...
                        getResultField(r, 'use_warmup', false), ...
                        getResultField(r, 'warmup_frames_run', NaN), ...
                        getResultField(r, 'use_prime_frames', false), ...
                        getResultField(r, 'prime_frames_run', NaN), ...
                        string(getResultField(r, 'fail_stage', "")), ...
                        string(getResultField(r, 'fail_message', "")), ...
                        r.warmup_overrun, ...
                        r.total_overrun, ...
                        r.warmup_bad_len_count, ...
                        r.bad_len_count, ...
                        r.received_samples, ...
                        r.theoretical_samples);

                    if isHardFormalFail(r)
                        fprintf('Hard fail detected (all formal frames invalid). Recreating rx immediately...\n');
                        rx = safeRecreateRx(rx, cfg);
                        ordinaryFailCount = 0;

                    elseif isFirstAttemptTransientFail(cfg, r, attempt)
                        fprintf('First-attempt transient failure detected. Recreating rx immediately...\n');
                        rx = safeRecreateRx(rx, cfg);
                        ordinaryFailCount = 0;

                    else
                        ordinaryFailCount = ordinaryFailCount + 1;

                        if ordinaryFailCount >= cfg.sdr.fail_recreate_threshold
                            fprintf('Ordinary FAIL threshold reached. Recreating rx for this slide...\n');
                            rx = safeRecreateRx(rx, cfg);
                            ordinaryFailCount = 0;
                        else
                            fprintf('Capture completed but not OK. Reusing same rx and retrying if allowed...\n');
                        end
                    end

                catch ME
                    lastErrMsg = string(ME.message);
                    fprintf(2, 'ERROR: %s\n', ME.message);
                    fprintf(2, 'Exception detected. Releasing and recreating rx for this slide...\n');

                    rx = safeRecreateRx(rx, cfg);
                    ordinaryFailCount = 0;

                    rr = makeEmptyResultRow();
                    rr.timestamp = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
                    rr.sample_id = sample_id;
                    rr.slide_index = slideMeta.slide_index;
                    rr.content_id = string(getSlideField(slideMeta, 'content_id', ""));
                    rr.notes = string(getSlideField(slideMeta, 'notes', ""));

                    rr.content_type = string(cfg.meta_common.content_type);
                    rr.font_name = string(cfg.meta_common.font_name);
                    rr.font_size_pt = cfg.meta_common.font_size_pt;
                    rr.theme = string(cfg.meta_common.theme);
                    rr.batch_notes = string(cfg.meta_common.notes);

                    rr.sdr_model = string(cfg.meta_common.sdr_model);
                    rr.antenna_model = string(cfg.meta_common.antenna_model);
                    rr.test_distance_cm = cfg.meta_common.test_distance_cm;
                    rr.environment = string(cfg.meta_common.environment);

                    rr.monitor_model = string(cfg.meta_common.monitor_model);
                    rr.monitor_resolution = string(cfg.meta_common.monitor_resolution);
                    rr.monitor_refresh_hz = cfg.meta_common.monitor_refresh_hz;

                    rr.ppt_filename = "";
                    rr.capture_filename = "";
                    rr.expected_frames = NaN;
                    rr.warmup_bad_len_count = NaN;
                    rr.bad_len_count = NaN;
                    rr.first_overrun_frame = NaN;

                    rr.status = "ERROR";
                    rr.retry_count = attempt - 1;
                    rr.error_message = lastErrMsg;

                    results(k) = rr;
                end

                pause(cfg.general.pause_between_attempts_s);
            end

        catch ME_outer
            lastErrMsg = string(ME_outer.message);
            fprintf(2, 'FATAL ERROR on slide %d: %s\n', slideMeta.slide_index, ME_outer.message);

            rr = makeEmptyResultRow();
            rr.timestamp = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            rr.sample_id = sample_id;
            rr.slide_index = slideMeta.slide_index;
            rr.content_id = string(getSlideField(slideMeta, 'content_id', ""));
            rr.notes = string(getSlideField(slideMeta, 'notes', ""));
            rr.status = "ERROR";
            rr.retry_count = cfg.general.retry_max;
            rr.error_message = lastErrMsg;
            results(k) = rr;
        end

        safeReleaseRx(rx);

        if ~success
            fprintf(2, 'FAILED on slide %d\n', slideMeta.slide_index);
            if strlength(lastErrMsg) > 0
                fprintf(2, 'Last error: %s\n', lastErrMsg);
            end
        end

        % -------- progress / ETA --------
        elapsed_batch_s = toc(t_batch);
        elapsed_item_s = toc(t_item);
        avg_per_item_s = elapsed_batch_s / k;
        remaining_items = n - k;
        eta_s = avg_per_item_s * remaining_items;
        eta_clock = datetime('now') + seconds(eta_s);

        if isfield(cfg, 'display') && isfield(cfg.display, 'show_progress_bar') && cfg.display.show_progress_bar
            bar_width = cfg.display.progress_bar_width;
        else
            bar_width = 28;
        end

        fprintf('%s\n', renderProgressLine(k, n, elapsed_item_s, elapsed_batch_s, avg_per_item_s, eta_s, eta_clock, bar_width));

        % -------- checkpoint --------
        if mod(k, cfg.general.checkpoint_every) == 0 || k == n
            results_partial = results(1:k);
            checkpointTable = struct2table(results_partial);

            checkpointMat = fullfile( ...
                cfg.general.checkpoint_dir, ...
                sprintf('capture_checkpoint_%03d.mat', k));

            checkpointCsv = fullfile( ...
                cfg.general.checkpoint_dir, ...
                sprintf('capture_checkpoint_%03d.csv', k));

            save(checkpointMat, 'results_partial');
            writetable(checkpointTable, checkpointCsv);

            fprintf('Checkpoint saved at item %03d\n', k);
            fprintf('  MAT: %s\n', checkpointMat);
            fprintf('  CSV: %s\n', checkpointCsv);
        end
    end

    % =========================================================
    % Final merge from current run + all existing CSV logs
    % =========================================================
    results_current = struct2table(results(1:n));
    [resultsTable, mergeInfo] = mergeAllCsvResults(cfg, results_current);

    writetable(resultsTable, cfg.general.final_log_csv);

    fprintf('\n========================================\n');
    fprintf('Batch capture finished.\n');
    fprintf('Current-run rows      : %d\n', mergeInfo.current_rows);
    fprintf('Existing CSV rows     : %d\n', mergeInfo.existing_rows);
    fprintf('Merged rows           : %d\n', mergeInfo.merged_rows);
    fprintf('Dropped duplicates    : %d\n', mergeInfo.duplicate_rows_removed);
    fprintf('Existing CSV files    : %d\n', mergeInfo.existing_file_count);
    fprintf('Final CSV saved to:\n%s\n', cfg.general.final_log_csv);
    fprintf('========================================\n');
end


function tf = isFirstAttemptTransientFail(cfg, r, attempt)
    tf = false;

    if attempt ~= 1
        return;
    end

    if ~isfield(cfg, 'sdr') || ~isfield(cfg.sdr, 'enable_first_attempt_transient_mode')
        return;
    end

    if ~cfg.sdr.enable_first_attempt_transient_mode
        return;
    end

    use_warmup = getResultField(r, 'use_warmup', true);
    if use_warmup
        return;
    end

    tf = ...
        isequaln(r.warmup_overrun, cfg.sdr.first_attempt_expect_warmup_overrun) && ...
        isequaln(r.warmup_bad_len_count, cfg.sdr.first_attempt_expect_warmup_bad_len) && ...
        isequaln(r.total_overrun, cfg.sdr.first_attempt_expect_total_overrun) && ...
        isequaln(r.bad_len_count, cfg.sdr.first_attempt_expect_bad_len);
end


function tf = isHardFormalFail(r)
    tf = false;

    formal_calls = getResultField(r, 'formal_calls', NaN);

    if isnan(formal_calls) || formal_calls <= 0
        return;
    end

    tf = ...
        isequaln(r.received_samples, 0) && ...
        isequaln(r.total_overrun, formal_calls) && ...
        isequaln(r.bad_len_count, formal_calls);
end


function line = renderProgressLine(k, n, item_s, elapsed_s, avg_s, eta_s, eta_clock, bar_width)
    frac = k / n;
    filled = round(frac * bar_width);
    filled = min(max(filled, 0), bar_width);

    bar = [repmat('=', 1, filled), repmat('-', 1, bar_width - filled)];

    line = sprintf(['Progress [%s] %3d/%3d (%.1f%%) | item %.1fs | elapsed %s | ', ...
                    'avg %.1fs/item | ETA %s | done ~ %s'], ...
        bar, k, n, 100*frac, item_s, fmtDuration(elapsed_s), avg_s, fmtDuration(eta_s), ...
        char(datetime(eta_clock, 'Format', 'HH:mm:ss')));
end


function s = fmtDuration(sec)
    sec = max(0, round(sec));
    h = floor(sec / 3600);
    m = floor(mod(sec, 3600) / 60);
    s2 = mod(sec, 60);

    if h > 0
        s = sprintf('%dh %02dm %02ds', h, m, s2);
    elseif m > 0
        s = sprintf('%dm %02ds', m, s2);
    else
        s = sprintf('%ds', s2);
    end
end


function [T_out, info] = mergeAllCsvResults(cfg, T_new)
    info = struct();
    info.current_rows = height(T_new);
    info.existing_rows = 0;
    info.merged_rows = height(T_new);
    info.duplicate_rows_removed = 0;
    info.existing_file_count = 0;

    allTables = {};
    totalExistingRows = 0;
    existingFileCount = 0;

    % ---- existing final capture_log.csv ----
    finalCsv = string(cfg.general.final_log_csv);
    if strlength(finalCsv) > 0 && isfile(finalCsv)
        T_final = readtable(finalCsv, 'TextType', 'string');
        allTables{end+1} = T_final; %#ok<AGROW>
        totalExistingRows = totalExistingRows + height(T_final);
        existingFileCount = existingFileCount + 1;
    end

    % ---- all checkpoint CSVs ----
    if strlength(string(cfg.general.checkpoint_dir)) > 0 && isfolder(cfg.general.checkpoint_dir)
        files = dir(fullfile(cfg.general.checkpoint_dir, 'capture_checkpoint_*.csv'));

        for i = 1:numel(files)
            f = fullfile(files(i).folder, files(i).name);
            if isfile(f)
                T_ckpt = readtable(f, 'TextType', 'string');
                allTables{end+1} = T_ckpt; %#ok<AGROW>
                totalExistingRows = totalExistingRows + height(T_ckpt);
                existingFileCount = existingFileCount + 1;
            end
        end
    end

    info.existing_rows = totalExistingRows;
    info.existing_file_count = existingFileCount;

    if isempty(allTables)
        T_out = T_new;
        return;
    end

    T_existing = allTables{1};
    for i = 2:numel(allTables)
        [T_existing, Ti] = alignTablesByVariables(T_existing, allTables{i});
        T_existing = [T_existing; Ti]; %#ok<AGROW>
    end

    [T_existing, T_new] = alignTablesByVariables(T_existing, T_new);

    T_existing.source_rank_tmp = zeros(height(T_existing), 1);
    T_new.source_rank_tmp = ones(height(T_new), 1);

    T_all = [T_existing; T_new];
    before_dedup_rows = height(T_all);

    if ismember("slide_index", string(T_all.Properties.VariableNames))
        [~, order] = sortrows(table(T_all.slide_index, T_all.source_rank_tmp), [1 2]);
        T_all = T_all(order, :);

        [~, ia] = unique(T_all.slide_index, 'last');
        T_all = T_all(sort(ia), :);

    elseif ismember("sample_id", string(T_all.Properties.VariableNames))
        [~, order] = sortrows(table(T_all.sample_id, T_all.source_rank_tmp), [1 2]);
        T_all = T_all(order, :);

        [~, ia] = unique(T_all.sample_id, 'last');
        T_all = T_all(sort(ia), :);
    end

    if ismember("slide_index", string(T_all.Properties.VariableNames))
        T_all = sortrows(T_all, "slide_index");
    elseif ismember("sample_id", string(T_all.Properties.VariableNames))
        T_all = sortrows(T_all, "sample_id");
    end

    T_all.source_rank_tmp = [];

    T_out = T_all;
    info.merged_rows = height(T_out);
    info.duplicate_rows_removed = before_dedup_rows - info.merged_rows;
end


function [A2, B2] = alignTablesByVariables(A, B)
    varsA = string(A.Properties.VariableNames);
    varsB = string(B.Properties.VariableNames);

    allVars = unique([varsA, varsB], 'stable');

    A2 = A;
    B2 = B;

    for v = allVars
        vn = char(v);

        if ~ismember(v, varsA)
            A2.(vn) = defaultColumnForLike(B2, vn, height(A2));
        end

        if ~ismember(v, varsB)
            B2.(vn) = defaultColumnForLike(A2, vn, height(B2));
        end
    end

    A2 = A2(:, cellstr(allVars));
    B2 = B2(:, cellstr(allVars));
end


function col = defaultColumnForLike(Tref, varName, nRows)
    if ismember(varName, string(Tref.Properties.VariableNames))
        sample = Tref.(varName);
        if isstring(sample)
            col = strings(nRows, 1);
        elseif islogical(sample)
            col = false(nRows, 1);
        elseif isnumeric(sample)
            col = nan(nRows, 1);
        else
            col = strings(nRows, 1);
        end
    else
        col = strings(nRows, 1);
    end
end


function row = buildResultRow(r, status, retry_count)
    row = makeEmptyResultRow();

    row.timestamp = string(r.timestamp);
    row.sample_id = r.sample_id;
    row.slide_index = r.slide_index;
    row.content_id = string(r.content_id);
    row.content_type = string(r.content_type);
    row.font_name = string(r.font_name);
    row.font_size_pt = r.font_size_pt;
    row.theme = string(r.theme);
    row.notes = string(r.notes);
    row.batch_notes = string(getResultField(r, 'batch_notes', ""));

    row.sdr_model = string(getResultField(r, 'sdr_model', ""));
    row.antenna_model = string(getResultField(r, 'antenna_model', ""));
    row.test_distance_cm = getResultField(r, 'test_distance_cm', NaN);
    row.environment = string(getResultField(r, 'environment', ""));

    row.monitor_model = string(getResultField(r, 'monitor_model', ""));
    row.monitor_resolution = string(getResultField(r, 'monitor_resolution', ""));
    row.monitor_refresh_hz = getResultField(r, 'monitor_refresh_hz', NaN);

    row.ppt_filename = string(r.ppt_filename);
    row.capture_filename = string(r.filename);

    row.received_samples = r.received_samples;
    row.theoretical_samples = r.theoretical_samples;
    row.expected_frames = getResultField(r, 'expected_frames', NaN);
    row.sample_margin = r.sample_margin;
    row.warmup_overrun = r.warmup_overrun;
    row.warmup_bad_len_count = getResultField(r, 'warmup_bad_len_count', NaN);
    row.total_overrun = r.total_overrun;
    row.bad_len_count = getResultField(r, 'bad_len_count', NaN);
    row.first_overrun_frame = getResultField(r, 'first_overrun_frame', NaN);
    row.elapsed_s = r.elapsed_s;

    row.ok = r.ok;
    row.status = string(status);
    row.retry_count = retry_count;
    row.error_message = "";
end


function row = makeEmptyResultRow()
    row = struct( ...
        'timestamp', "", ...
        'sample_id', NaN, ...
        'slide_index', NaN, ...
        'content_id', "", ...
        'content_type', "", ...
        'font_name', "", ...
        'font_size_pt', NaN, ...
        'theme', "", ...
        'notes', "", ...
        'batch_notes', "", ...
        'sdr_model', "", ...
        'antenna_model', "", ...
        'test_distance_cm', NaN, ...
        'environment', "", ...
        'monitor_model', "", ...
        'monitor_resolution', "", ...
        'monitor_refresh_hz', NaN, ...
        'ppt_filename', "", ...
        'capture_filename', "", ...
        'received_samples', NaN, ...
        'theoretical_samples', NaN, ...
        'expected_frames', NaN, ...
        'sample_margin', NaN, ...
        'warmup_overrun', NaN, ...
        'warmup_bad_len_count', NaN, ...
        'total_overrun', NaN, ...
        'bad_len_count', NaN, ...
        'first_overrun_frame', NaN, ...
        'elapsed_s', NaN, ...
        'ok', false, ...
        'status', "", ...
        'retry_count', NaN, ...
        'error_message', "" ...
    );
end


function v = getSlideField(s, name, defaultVal)
    if isfield(s, name)
        v = s.(name);
    else
        v = defaultVal;
    end
end


function v = getResultField(s, name, defaultVal)
    if isfield(s, name)
        v = s.(name);
    else
        v = defaultVal;
    end
end


function safeReleaseRx(rx)
    if ~isempty(rx)
        try
            release(rx);
        catch
        end
    end
end


function rx = safeRecreateRx(rxOld, cfg)
    safeReleaseRx(rxOld);
    clear rxOld

    if isfield(cfg, 'sdr') && isfield(cfg.sdr, 'pause_before_rx_recreate_s')
        if cfg.sdr.pause_before_rx_recreate_s > 0
            pause(cfg.sdr.pause_before_rx_recreate_s);
        end
    end

    rx = x310CreateRx(cfg);

    if isfield(cfg, 'sdr') && isfield(cfg.sdr, 'pause_after_rx_create_s')
        if cfg.sdr.pause_after_rx_create_s > 0
            pause(cfg.sdr.pause_after_rx_create_s);
        end
    end
end
