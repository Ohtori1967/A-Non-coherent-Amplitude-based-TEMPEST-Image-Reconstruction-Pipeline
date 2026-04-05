function [pendingSlideList, completedLog, nextSampleId] = filterPendingSlides(cfg, slideList)
%FILTERPENDINGSLIDES Recover completed slides from all incremental checkpoints.
%
% Returns:
%   pendingSlideList : slides still to capture
%   completedLog     : merged completed rows reconstructed from checkpoints
%   nextSampleId     : next sample id after last checkpointed sample

    completedLog = table();
    nextSampleId = 1;

    ckptDir = string(cfg.general.checkpoint_dir);
    if strlength(ckptDir) == 0 || ~isfolder(ckptDir)
        pendingSlideList = slideList;
        return;
    end

    files = dir(fullfile(ckptDir, 'capture_checkpoint_*.csv'));
    if isempty(files)
        pendingSlideList = slideList;
        return;
    end

    % merge all checkpoint CSVs
    completedLog = readtable(fullfile(files(1).folder, files(1).name), 'TextType', 'string');
    for i = 2:numel(files)
        Ti = readtable(fullfile(files(i).folder, files(i).name), 'TextType', 'string');
        [completedLog, Ti] = alignTablesByVariables(completedLog, Ti);
        completedLog = [completedLog; Ti]; %#ok<AGROW>
    end

    completedLog = dedupResultTable(completedLog);

    vars = string(completedLog.Properties.VariableNames);

    % next sample id
    if ismember("sample_id", vars)
        validSampleMask = ~isnan(completedLog.sample_id);
        if any(validSampleMask)
            nextSampleId = max(completedLog.sample_id(validSampleMask)) + 1;
        end
    end

    % only PASS / RETRY_PASS count as completed
    doneSlideIdx = [];
    if all(ismember(["slide_index","status"], vars))
        okMask = (completedLog.status == "PASS") | (completedLog.status == "RETRY_PASS");
        doneSlideIdx = unique(completedLog.slide_index(okMask));
    end

    keepMask = true(size(slideList));
    for k = 1:numel(slideList)
        keepMask(k) = ~ismember(slideList(k).slide_index, doneSlideIdx);
    end

    pendingSlideList = slideList(keepMask);

    fprintf('Recovered checkpoint rows: %d\n', height(completedLog));
    fprintf('Already completed slides: %d\n', numel(doneSlideIdx));
    fprintf('Pending slides: %d\n', numel(pendingSlideList));
    fprintf('Next sample_id: %d\n', nextSampleId);
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
