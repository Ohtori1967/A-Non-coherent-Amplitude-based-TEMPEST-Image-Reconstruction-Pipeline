function [pendingSlideList, doneSlideIdx, sourceCsv, nextSampleId] = filterPendingSlides(cfg, slideList)
%FILTERPENDINGSLIDES Remove already completed slides based on existing CSV log.
%
% [pendingSlideList, doneSlideIdx, sourceCsv, nextSampleId] = ...
%     filterPendingSlides(cfg, slideList)

    doneSlideIdx = [];
    sourceCsv = "";
    nextSampleId = 1;

    % ---------- prefer final log ----------
    if strlength(string(cfg.general.final_log_csv)) > 0 && isfile(cfg.general.final_log_csv)
        sourceCsv = string(cfg.general.final_log_csv);
    else
        % ---------- fallback to latest checkpoint CSV ----------
        if strlength(string(cfg.general.checkpoint_dir)) > 0 && isfolder(cfg.general.checkpoint_dir)
            files = dir(fullfile(cfg.general.checkpoint_dir, 'capture_checkpoint_*.csv'));
            if ~isempty(files)
                [~, idx] = max([files.datenum]);
                sourceCsv = string(fullfile(files(idx).folder, files(idx).name));
            end
        end
    end

    % ---------- no existing log ----------
    if strlength(sourceCsv) == 0
        pendingSlideList = slideList;
        return;
    end

    T = readtable(sourceCsv, 'TextType', 'string');

    vars = string(T.Properties.VariableNames);
    if ~all(ismember(["slide_index", "status"], vars))
        warning('filterPendingSlides:BadCSV', ...
            'CSV does not contain slide_index/status. Resume is skipped.');
        pendingSlideList = slideList;
        return;
    end

    % ---------- recover next sample id ----------
    if ismember("sample_id", vars)
        validSampleMask = ~isnan(T.sample_id);
        if any(validSampleMask)
            nextSampleId = max(T.sample_id(validSampleMask)) + 1;
        end
    end

    % ---------- remove already completed slides ----------
    okMask = (T.status == "PASS") | (T.status == "RETRY_PASS");
    doneSlideIdx = unique(T.slide_index(okMask));

    keepMask = true(size(slideList));
    for k = 1:numel(slideList)
        keepMask(k) = ~ismember(slideList(k).slide_index, doneSlideIdx);
    end

    pendingSlideList = slideList(keepMask);

    fprintf('Resume source CSV:\n%s\n', sourceCsv);
    fprintf('Already completed slides: %d\n', numel(doneSlideIdx));
    fprintf('Pending slides: %d\n', numel(pendingSlideList));
    fprintf('Next sample_id: %d\n', nextSampleId);
end
