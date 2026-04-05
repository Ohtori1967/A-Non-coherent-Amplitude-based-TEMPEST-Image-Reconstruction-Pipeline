clear; clc;

cfg = config_capture();

client = [];

try
    % ---------- print key config ----------
    fprintf('================ CONFIG SUMMARY ================\n');
    fprintf('Fs                 : %.3f MSPS\n', cfg.sdr.fs / 1e6);
    fprintf('Fc                 : %.3f MHz\n', cfg.sdr.fc / 1e6);
    fprintf('Capture time       : %.3f s\n', cfg.sdr.capture_time_s);
    fprintf('SamplesPerFrame    : %d\n', cfg.sdr.samplesPerFrame);
    fprintf('Use warm-up        : %d\n', cfg.sdr.use_warmup);
    fprintf('Warm-up frames     : %d\n', cfg.sdr.warmup_frames);
    fprintf('Use prime frames   : %d\n', cfg.sdr.use_prime_frames);
    fprintf('Prime frames       : %d\n', cfg.sdr.prime_frames);
    fprintf('Prime first only   : %d\n', cfg.sdr.prime_only_on_first_attempt);
    fprintf('Retry max          : %d\n', cfg.general.retry_max);
    fprintf('Fail recreate thr. : %d\n', cfg.sdr.fail_recreate_threshold);
    fprintf('1st transient mode : %d\n', cfg.sdr.enable_first_attempt_transient_mode);
    fprintf('Cleanup stale samp.: %d\n', cfg.general.cleanup_uncheckpointed_samples);
    fprintf('===============================================\n\n');

    % ---------- connect PPT remote ----------
    client = ppt_remote_client(cfg.ppt.server_ip, cfg.ppt.server_port);

    % ---------- determine output directory ----------
    if strlength(string(cfg.general.resume_existing_out_dir)) > 0
        % ===== Resume existing batch =====
        cfg.general.out_dir = char(cfg.general.resume_existing_out_dir);
        cfg.general.checkpoint_dir = fullfile(cfg.general.out_dir, 'checkpoints');
        cfg.general.final_log_csv = fullfile(cfg.general.out_dir, 'capture_log.csv');

        if ~exist(cfg.general.out_dir, 'dir')
            error('run_capture_batch:ResumeDirNotFound', ...
                'resume_existing_out_dir does not exist:\n%s', cfg.general.out_dir);
        end

        if ~exist(cfg.general.checkpoint_dir, 'dir')
            mkdir(cfg.general.checkpoint_dir);
        end

        fprintf('Resume mode enabled.\n');
        fprintf('Using existing output directory:\n%s\n\n', cfg.general.out_dir);

    else
        % ===== Create new batch directory =====
        try
            ppt_name = pptRemoteFile(client);
        catch
            ppt_name = cfg.ppt.filename_fallback;
        end

        ppt_name = string(ppt_name);

        [~, nameOnly, ~] = fileparts(char(ppt_name));
        if ~isempty(nameOnly)
            ppt_name = string(nameOnly);
        end

        ppt_name = regexprep(ppt_name, '[^\w\-]', '_');
        ppt_name = regexprep(ppt_name, '_+', '_');
        ppt_name = strip(ppt_name, '_');

        if strlength(ppt_name) == 0
            ppt_name = "ppt_capture";
        end

        ts = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));

        folder_name = sprintf('%s_CF_%.3fMHz_FS_%.3fMSPS_%s', ...
            ppt_name, cfg.sdr.fc/1e6, cfg.sdr.fs/1e6, ts);

        cfg.general.out_dir = fullfile(cfg.general.out_root, folder_name);
        cfg.general.checkpoint_dir = fullfile(cfg.general.out_dir, 'checkpoints');
        cfg.general.final_log_csv = fullfile(cfg.general.out_dir, 'capture_log.csv');

        if ~exist(cfg.general.out_dir, 'dir')
            mkdir(cfg.general.out_dir);
        end
        if ~exist(cfg.general.checkpoint_dir, 'dir')
            mkdir(cfg.general.checkpoint_dir);
        end

        fprintf('New batch mode.\n');
        fprintf('Output directory:\n%s\n\n', cfg.general.out_dir);
    end

    % ---------- build slide list ----------
    slideList = buildSlideList(cfg);
    if isempty(slideList)
        error('run_capture_batch:EmptySlideList', 'slideList is empty.');
    end

    fprintf('Original slide count: %d\n', numel(slideList));

    nextSampleId = 1;
    completedLog = table();

    % ---------- resume / rebuild from all checkpoints ----------
    if cfg.general.resume_if_possible
        [slideList, completedLog, nextSampleId] = filterPendingSlides(cfg, slideList);

        if ~isempty(completedLog)
            fprintf('Recovered completed rows from checkpoints: %d\n', height(completedLog));
            if ismember("slide_index", string(completedLog.Properties.VariableNames))
                doneSlideIdx = unique(completedLog.slide_index(~isnan(completedLog.slide_index)));
                fprintf('Completed slide indices already found:\n');
                disp(doneSlideIdx(:).');
            end
        end

        % ---------- cleanup stale sample artifacts after last checkpoint ----------
        if isfield(cfg.general, 'cleanup_uncheckpointed_samples') && cfg.general.cleanup_uncheckpointed_samples
            cleanupUncheckpointedArtifacts(cfg, nextSampleId);
        end
    end

    if isempty(slideList)
        fprintf('All slides are already completed. Nothing to do.\n');

        % still rebuild final log from checkpoints
        finalTable = rebuildFinalLogFromCheckpoints(cfg);
        if ~isempty(finalTable)
            writetable(finalTable, cfg.general.final_log_csv);
            fprintf('Rebuilt final CSV from checkpoints:\n%s\n', cfg.general.final_log_csv);
        end
        return;
    end

    fprintf('Slides to capture this run: %d\n', numel(slideList));
    fprintf('Starting sample_id for this run: %d\n\n', nextSampleId);

    % ---------- batch capture ----------
    resultsTable = captureSlideList(cfg, client, slideList, nextSampleId);

    disp(resultsTable);
    fprintf('Batch capture finished.\n');
    fprintf('Final CSV:\n%s\n', cfg.general.final_log_csv);

catch ME
    fprintf(2, '\nBATCH ERROR: %s\n', ME.message);
    rethrow(ME);
end

if ~isempty(client)
    try
        clear client
    catch
    end
end


function cleanupUncheckpointedArtifacts(cfg, nextSampleId)
%CLEANUPUNCHECKPOINTEDARTIFACTS Delete stale sample artifacts whose
%sample_id >= nextSampleId before resuming capture.

    outDir = cfg.general.out_dir;

    if ~isfolder(outDir)
        return;
    end

    fprintf('Checking for stale uncheckpointed artifacts in:\n%s\n', outDir);
    fprintf('Any artifact with sample_id >= %d will be removed.\n', nextSampleId);

    exts = {'.mat', '.png', '.json', '.txt', '.npy'};
    deletedCount = 0;

    files = dir(fullfile(outDir, 'sample_*'));
    for k = 1:numel(files)
        if files(k).isdir
            continue;
        end

        fname = files(k).name;
        [~, ~, ext] = fileparts(fname);

        if ~ismember(lower(ext), exts)
            continue;
        end

        tok = regexp(fname, '^sample_(\d+)_', 'tokens', 'once');
        if isempty(tok)
            continue;
        end

        sid = str2double(tok{1});
        if isnan(sid)
            continue;
        end

        if sid >= nextSampleId
            fpath = fullfile(files(k).folder, files(k).name);
            try
                delete(fpath);
                deletedCount = deletedCount + 1;
                fprintf('  deleted: %s\n', fname);
            catch ME
                fprintf(2, '  failed to delete %s : %s\n', fname, ME.message);
            end
        end
    end

    fprintf('Cleanup finished. Deleted %d stale artifact(s).\n\n', deletedCount);
end


function T = rebuildFinalLogFromCheckpoints(cfg)
%REBUILDFINALLOGFROMCHECKPOINTS Merge all incremental checkpoint CSVs.

    if ~isfolder(cfg.general.checkpoint_dir)
        T = table();
        return;
    end

    files = dir(fullfile(cfg.general.checkpoint_dir, 'capture_checkpoint_*.csv'));
    if isempty(files)
        T = table();
        return;
    end

    T = readtable(fullfile(files(1).folder, files(1).name), 'TextType', 'string');
    for i = 2:numel(files)
        Ti = readtable(fullfile(files(i).folder, files(i).name), 'TextType', 'string');
        [T, Ti] = alignTablesByVariables(T, Ti);
        T = [T; Ti]; %#ok<AGROW>
    end

    T = dedupResultTable(T);
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


function T = dedupResultTable(T)
    if isempty(T)
        return;
    end

    if ismember("slide_index", string(T.Properties.VariableNames))
        T = sortrows(T, "slide_index");
        [~, ia] = unique(T.slide_index, 'last');
        T = T(sort(ia), :);
        T = sortrows(T, "slide_index");
    elseif ismember("sample_id", string(T.Properties.VariableNames))
        T = sortrows(T, "sample_id");
        [~, ia] = unique(T.sample_id, 'last');
        T = T(sort(ia), :);
        T = sortrows(T, "sample_id");
    end
end
