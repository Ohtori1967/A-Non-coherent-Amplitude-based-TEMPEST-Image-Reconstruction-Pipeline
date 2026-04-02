clear; clc;

% =====================================
% Basic parameters
% =====================================
ip_addr = '192.168.40.2';
fc = 742.5e6;
gain = 20;

% ===== 61.44 MSPS = 184.32e6 / 3 =====
masterClockRate = 184.32e6;
decimationFactor = 3;
Fs = masterClockRate / decimationFactor;

capture_time_s = 0.2;       % target continuous capture duration
samplesPerFrame = 20000;    % can now be 20000, 24000, etc.
num_trials = 20;
num_warmup_frames = 20;

pause_between_trials_s = 0.2;
outputDataType = 'single';

summary_csv = 'x310_capture_acceptance_spf.csv';
frame_log_dir = 'x310_frame_logs';

if ~exist(frame_log_dir, 'dir')
    mkdir(frame_log_dir);
end

% =====================================
% Derived quantities
% =====================================
theoretical_samples = round(Fs * capture_time_s);

n_full_frames = floor(theoretical_samples / samplesPerFrame);
tail_needed = theoretical_samples - n_full_frames * samplesPerFrame;

if tail_needed == 0
    capture_mode = "exact_multiple";
else
    capture_mode = "non_multiple";
end

fprintf('=============================================================\n');
fprintf('X310 flexible-SPF acceptance test\n');
fprintf('IP Address              : %s\n', ip_addr);
fprintf('Center Frequency        : %.3f MHz\n', fc/1e6);
fprintf('Gain                    : %.1f dB\n', gain);
fprintf('MasterClockRate         : %.3f MHz\n', masterClockRate/1e6);
fprintf('DecimationFactor        : %d\n', decimationFactor);
fprintf('Sampling Rate           : %.3f MSPS\n', Fs/1e6);
fprintf('Capture Time            : %.6f s\n', capture_time_s);
fprintf('SamplesPerFrame         : %d\n', samplesPerFrame);
fprintf('Theoretical Samples     : %d\n', theoretical_samples);
fprintf('Full Frames             : %d\n', n_full_frames);
fprintf('Tail Needed             : %d\n', tail_needed);
fprintf('Capture Mode            : %s\n', capture_mode);
fprintf('Warm-up Frames          : %d\n', num_warmup_frames);
fprintf('Trials                  : %d\n', num_trials);
fprintf('OutputDataType          : %s\n', outputDataType);
fprintf('Pause Between Trials    : %.3f s\n', pause_between_trials_s);
fprintf('Frame Log Directory     : %s\n', frame_log_dir);
fprintf('Summary CSV             : %s\n', summary_csv);
fprintf('=============================================================\n\n');

% =====================================
% Results columns
% =====================================
% [1] Trial
% [2] TheoreticalSamples
% [3] FullFrames
% [4] TailNeeded
% [5] ReceivedSamples
% [6] SampleMargin
% [7] WarmupOverruns
% [8] TotalOverruns
% [9] BadLenCount
% [10] FirstOverrunFrame
% [11] TailFrameUsed
% [12] PassFlag
% [13] ElapsedTime_s
results = zeros(num_trials, 13);

for t = 1:num_trials
    fprintf('---------------- Trial %d / %d ----------------\n', t, num_trials);

    if exist('rx', 'var')
        release(rx);
        clear rx;
    end

    rx = comm.SDRuReceiver( ...
        'Platform', 'X310', ...
        'IPAddress', ip_addr, ...
        'CenterFrequency', fc, ...
        'MasterClockRate', masterClockRate, ...
        'DecimationFactor', decimationFactor, ...
        'Gain', gain, ...
        'SamplesPerFrame', samplesPerFrame, ...
        'OutputDataType', outputDataType);

    % =====================================
    % Warm-up
    % =====================================
    warmup_overrun = 0;
    warmup_ok = true;

    for k = 1:num_warmup_frames
        try
            [~, ~, ov_w] = rx();
            warmup_overrun = warmup_overrun + double(ov_w);
        catch ME
            warmup_ok = false;
            fprintf('  Warm-up failed at frame %d: %s\n', k, ME.message);
            break;
        end
    end

    if ~warmup_ok
        release(rx);
        clear rx;

        results(t, :) = [ ...
            t, theoretical_samples, n_full_frames, tail_needed, ...
            0, -theoretical_samples, warmup_overrun, NaN, NaN, NaN, NaN, ...
            0, NaN];

        fprintf('  Warm-up Overruns      : %d\n', warmup_overrun);
        fprintf('  Result                : FAIL (warm-up failed)\n\n');

        pause(pause_between_trials_s);
        continue;
    end

    % =====================================
    % Formal capture
    % =====================================
    total_len = 0;
    total_overrun = 0;
    bad_len_count = 0;
    first_overrun_frame = NaN;
    tail_frame_used = 0;

    % For exact_multiple: only full frames
    % For non_multiple: full frames + 1 extra frame
    if tail_needed == 0
        max_formal_calls = n_full_frames;
    else
        max_formal_calls = n_full_frames + 1;
    end

    % frame_log columns:
    % [1] CallIdx
    % [2] Len
    % [3] Overrun
    % [4] CumulativeLen
    frame_log = zeros(max_formal_calls, 4);

    formal_ok = true;

    tic;
    for k = 1:max_formal_calls
        try
            [~, len, overrun] = rx();

            len = double(len);
            overrun = double(overrun);

            total_len = total_len + len;
            total_overrun = total_overrun + overrun;

            if len ~= samplesPerFrame
                bad_len_count = bad_len_count + 1;
            end

            if isnan(first_overrun_frame) && (overrun ~= 0)
                first_overrun_frame = k;
            end

            frame_log(k, :) = [k, len, overrun, total_len];

            % exact_multiple: read exactly n_full_frames calls
            % non_multiple: after the extra tail frame arrives, stop
            if (tail_needed ~= 0) && (k == max_formal_calls)
                tail_frame_used = 1;
            end

        catch ME
            formal_ok = false;
            fprintf('  Formal capture failed at call %d: %s\n', k, ME.message);
            frame_log = frame_log(1:max(k-1,1), :);
            break;
        end
    end
    elapsed_s = toc;

    release(rx);
    clear rx;

    if ~formal_ok
        sample_margin = total_len - theoretical_samples;

        results(t, :) = [ ...
            t, theoretical_samples, n_full_frames, tail_needed, ...
            total_len, sample_margin, ...
            warmup_overrun, total_overrun, bad_len_count, first_overrun_frame, ...
            tail_frame_used, 0, elapsed_s];

        frame_log_table = array2table(frame_log, ...
            'VariableNames', {'CallIdx', 'Len', 'Overrun', 'CumulativeLen'});
        frame_log_name = fullfile(frame_log_dir, sprintf('trial_%02d_frame_log.csv', t));
        writetable(frame_log_table, frame_log_name);

        fprintf('  Warm-up Overruns      : %d\n', warmup_overrun);
        fprintf('  Received Samples      : %d\n', total_len);
        fprintf('  Sample Margin         : %+d\n', sample_margin);
        fprintf('  Total Overruns        : %d\n', total_overrun);
        fprintf('  Bad Len Count         : %d\n', bad_len_count);
        fprintf('  Tail Frame Used       : %d\n', tail_frame_used);
        fprintf('  Result                : FAIL (formal capture exception)\n');
        fprintf('  Frame log saved to    : %s\n\n', frame_log_name);

        pause(pause_between_trials_s);
        continue;
    end

    % =====================================
    % Final metrics and pass/fail
    % =====================================
    sample_margin = total_len - theoretical_samples;

    if tail_needed == 0
        % strict exact check
        pass_flag = (total_overrun == 0) && ...
                    (bad_len_count == 0) && ...
                    (total_len == theoretical_samples);
    else
        % flexible check:
        % 1) no overrun
        % 2) all calls still returned normal frame length
        % 3) total capture covers the target theoretical length
        % 4) positive margin is allowed, because one extra frame was used
        pass_flag = (total_overrun == 0) && ...
                    (bad_len_count == 0) && ...
                    (total_len >= theoretical_samples);
    end

    results(t, :) = [ ...
        t, theoretical_samples, n_full_frames, tail_needed, ...
        total_len, sample_margin, ...
        warmup_overrun, total_overrun, bad_len_count, first_overrun_frame, ...
        tail_frame_used, pass_flag, elapsed_s];

    fprintf('  Warm-up Overruns      : %d\n', warmup_overrun);
    fprintf('  Received Samples      : %d\n', total_len);
    fprintf('  Sample Margin         : %+d\n', sample_margin);
    fprintf('  Total Overruns        : %d\n', total_overrun);
    fprintf('  Bad Len Count         : %d\n', bad_len_count);
    if ~isnan(first_overrun_frame)
        fprintf('  First Overrun Frame   : %d\n', first_overrun_frame);
    else
        fprintf('  First Overrun Frame   : N/A\n');
    end
    fprintf('  Tail Frame Used       : %d\n', tail_frame_used);
    fprintf('  Elapsed Time          : %.6f s\n', elapsed_s);

    if pass_flag
        fprintf('  Result                : PASS\n');
    else
        fprintf('  Result                : FAIL\n');
    end

    frame_log_table = array2table(frame_log, ...
        'VariableNames', {'CallIdx', 'Len', 'Overrun', 'CumulativeLen'});
    frame_log_name = fullfile(frame_log_dir, sprintf('trial_%02d_frame_log.csv', t));
    writetable(frame_log_table, frame_log_name);
    fprintf('  Frame log saved to    : %s\n\n', frame_log_name);

    pause(pause_between_trials_s);
end

% =====================================
% Summary table
% =====================================
results_table = array2table(results, ...
    'VariableNames', { ...
        'Trial', ...
        'TheoreticalSamples', ...
        'FullFrames', ...
        'TailNeeded', ...
        'ReceivedSamples', ...
        'SampleMargin', ...
        'WarmupOverruns', ...
        'TotalOverruns', ...
        'BadLenCount', ...
        'FirstOverrunFrame', ...
        'TailFrameUsed', ...
        'PassFlag', ...
        'ElapsedTime_s'});

disp(results_table);

num_pass = sum(results_table.PassFlag == 1);
fprintf('=============================================================\n');
fprintf('Passed trials: %d / %d\n', num_pass, num_trials);

if num_pass == num_trials
    fprintf('Final verdict: ACCEPTED\n');
else
    fprintf('Final verdict: NOT ACCEPTED\n');
end
fprintf('=============================================================\n');

writetable(results_table, summary_csv);
fprintf('Summary results saved to %s\n', summary_csv);