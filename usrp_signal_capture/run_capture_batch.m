clear; clc;

cfg = config_capture();

client = [];

try
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

        % keep only base file name
        [~, nameOnly, ~] = fileparts(char(ppt_name));
        if ~isempty(nameOnly)
            ppt_name = string(nameOnly);
        end

        % sanitize folder name
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

    % ---------- optional resume filter ----------
    if cfg.general.resume_if_possible
        [slideList, doneSlideIdx, sourceCsv, nextSampleId] = filterPendingSlides(cfg, slideList); %#ok<ASGLU>

        if ~isempty(doneSlideIdx)
            fprintf('Completed slide indices already found:\n');
            disp(doneSlideIdx(:).');
        end
    end

    if isempty(slideList)
        fprintf('All slides are already completed. Nothing to do.\n');
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