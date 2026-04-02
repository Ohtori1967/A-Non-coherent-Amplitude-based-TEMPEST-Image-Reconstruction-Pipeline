function resultsTable = captureSlideList(cfg, client, slideList, startSampleId)
%CAPTURESLIDELIST Batch capture a list of slides with retry and checkpoints.
%
% resultsTable = captureSlideList(cfg, client, slideList, startSampleId)

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

    fprintf('========================================\n');
    fprintf('Batch capture started.\n');
    fprintf('Total slides: %d\n', n);
    fprintf('Output dir : %s\n', cfg.general.out_dir);
    fprintf('Checkpoint : every %d slide(s)\n', cfg.general.checkpoint_every);
    fprintf('Pause between attempts: %.3f s\n', cfg.general.pause_between_attempts_s);
    fprintf('Starting sample_id: %d\n', startSampleId);
    fprintf('========================================\n');

    for k = 1:n
        slideMeta = slideList(k);
        sample_id = startSampleId + k - 1;

        fprintf('\n----------------------------------------\n');
        fprintf('Item %03d / %03d | sample %03d | slide %03d\n', ...
            k, n, sample_id, slideMeta.slide_index);

        success = false;
        lastErrMsg = "";

        for attempt = 1:(cfg.general.retry_max + 1)
            rx = [];

            try
                fprintf('Attempt %d ...\n', attempt);

                % ---------- create a fresh rx for each attempt ----------
                rx = x310CreateRx(cfg);

                r = captureOneSlide(cfg, client, rx, slideMeta, sample_id);

                % ---------- always release after one attempt ----------
                try
                    release(rx);
                catch
                end
                rx = [];

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
                else
                    fprintf('Capture completed but not OK, retrying if allowed...\n');
                end

            catch ME
                lastErrMsg = string(ME.message);
                fprintf(2, 'ERROR: %s\n', ME.message);

                if ~isempty(rx)
                    try
                        release(rx);
                    catch
                    end
                    rx = [];
                end

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

            % ---------- pause between attempts ----------
            pause(cfg.general.pause_between_attempts_s);
        end

        if ~success
            fprintf(2, 'FAILED on slide %d\n', slideMeta.slide_index);
            if strlength(lastErrMsg) > 0
                fprintf(2, 'Last error: %s\n', lastErrMsg);
            end
        end

        % ---------- checkpoint ----------
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

    results_final = results(1:n);
    resultsTable = struct2table(results_final);
    writetable(resultsTable, cfg.general.final_log_csv);

    fprintf('\n========================================\n');
    fprintf('Batch capture finished.\n');
    fprintf('Final CSV saved to:\n%s\n', cfg.general.final_log_csv);
    fprintf('========================================\n');
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