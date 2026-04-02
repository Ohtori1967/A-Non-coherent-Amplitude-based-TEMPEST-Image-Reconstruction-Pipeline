function result = x310CaptureOnce(cfg, rx, outDir, meta)
%X310CAPTUREONCE Capture one IQ record from an existing X310 rx object.
% Supports both exact-multiple and non-multiple SamplesPerFrame cases.
% Save MAT only when capture passes acceptance criteria.
%
% exact_multiple mode:
%   theoretical_samples can be divided by samplesPerFrame exactly
%   pass criteria:
%       warmup_overrun == 0
%       total_overrun  == 0
%       bad_len_count  == 0
%       total_len      == theoretical_samples
%
% non_multiple mode:
%   theoretical_samples cannot be divided by samplesPerFrame exactly
%   capture full frames plus one extra tail frame
%   pass criteria:
%       warmup_overrun == 0
%       total_overrun  == 0
%       bad_len_count  == 0
%       total_len      >= theoretical_samples
%
% Saved IQ is cropped to exactly theoretical_samples on success.

    arguments
        cfg struct
        rx
        outDir (1,:) char
        meta struct = struct()
    end

    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    sdr = cfg.sdr;

    Fs = sdr.fs;
    Fc = sdr.fc;
    capture_time_s = sdr.capture_time_s;
    theoretical_samples = round(Fs * capture_time_s);

    samplesPerFrame = sdr.samplesPerFrame;
    n_full_frames = floor(theoretical_samples / samplesPerFrame);
    tail_needed = theoretical_samples - n_full_frames * samplesPerFrame;

    if tail_needed == 0
        capture_mode = "exact_multiple";
        formal_calls = n_full_frames;
        tail_frame_used = false;
    else
        capture_mode = "non_multiple";
        formal_calls = n_full_frames + 1;
        tail_frame_used = true;
    end

    ts = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));

    sample_id = getMetaField(meta, 'sample_id', 1);
    slide_index = getMetaField(meta, 'slide_index', NaN);

    filename = sprintf( ...
        'sample_%03d_slide%03d_CF_%.3fMHz_FS_%.3fMSPS_T%.1fs_%s.mat', ...
        sample_id, slide_index, Fc/1e6, Fs/1e6, capture_time_s, ts);

    fullpath = fullfile(outDir, filename);

    % =========================================================
    % warm-up
    % =========================================================
    warmup_overrun = 0;
    warmup_bad_len_count = 0;
    warmup_ok = true;
    warmup_fail_message = "";

    for k = 1:sdr.warmup_frames
        try
            [~, len_w, ov_w] = rx();
            len_w = double(len_w);
            ov_w = double(ov_w);

            warmup_overrun = warmup_overrun + ov_w;
            if len_w ~= samplesPerFrame
                warmup_bad_len_count = warmup_bad_len_count + 1;
            end
        catch ME
            warmup_ok = false;
            warmup_fail_message = string(ME.message);
            break;
        end
    end

    % warm-up failed: directly return fail
    if ~warmup_ok
        result = struct();
        result.ok = false;
        result.filename = "";
        result.fullpath = "";
        result.timestamp = char(ts);
        result.received_samples = 0;
        result.theoretical_samples = theoretical_samples;
        result.expected_frames = n_full_frames;
        result.formal_calls = formal_calls;
        result.sample_margin = -theoretical_samples;
        result.warmup_overrun = warmup_overrun;
        result.warmup_bad_len_count = warmup_bad_len_count;
        result.total_overrun = NaN;
        result.bad_len_count = NaN;
        result.first_overrun_frame = NaN;
        result.elapsed_s = NaN;
        result.capture_mode = char(capture_mode);
        result.tail_needed = tail_needed;
        result.tail_frame_used = double(tail_frame_used);
        result.fail_stage = 'warmup';
        result.fail_message = char(warmup_fail_message);
        return;
    end

    % =========================================================
    % formal capture
    % =========================================================
    % Allocate enough room for all formal calls
    alloc_len = formal_calls * samplesPerFrame;
    iq_all = complex(zeros(alloc_len, 1, sdr.outputDataType));

    write_idx = 1;
    total_len = 0;
    total_overrun = 0;
    bad_len_count = 0;
    first_overrun_frame = NaN;
    formal_ok = true;
    formal_fail_message = "";

    % optional per-call log
    frame_log = zeros(formal_calls, 4);
    % columns:
    % [1] call_idx
    % [2] len
    % [3] overrun
    % [4] cumulative_len

    t0 = tic;
    for k = 1:formal_calls
        try
            [x, len, ov] = rx();

            len = double(len);
            ov = double(ov);

            total_len = total_len + len;
            total_overrun = total_overrun + ov;

            if len ~= samplesPerFrame
                bad_len_count = bad_len_count + 1;
            end

            if isnan(first_overrun_frame) && (ov ~= 0)
                first_overrun_frame = k;
            end

            if len > 0
                end_idx = write_idx + len - 1;
                if end_idx > numel(iq_all)
                    formal_ok = false;
                    formal_fail_message = "Buffer overflow while writing IQ samples.";
                    break;
                end
                iq_all(write_idx:end_idx) = x(1:len);
                write_idx = end_idx + 1;
            end

            frame_log(k, :) = [k, len, ov, total_len];

        catch ME
            formal_ok = false;
            formal_fail_message = string(ME.message);
            frame_log = frame_log(1:max(k-1, 1), :);
            break;
        end
    end
    elapsed_s = toc(t0);

    if ~formal_ok
        filename = "";
        fullpath = "";
        ok = false;
        iq = complex([], [], sdr.outputDataType); %#ok<NASGU>
        sample_margin = total_len - theoretical_samples;

        result = struct();
        result.ok = ok;
        result.filename = char(filename);
        result.fullpath = char(fullpath);
        result.timestamp = char(ts);
        result.received_samples = total_len;
        result.theoretical_samples = theoretical_samples;
        result.expected_frames = n_full_frames;
        result.formal_calls = formal_calls;
        result.sample_margin = sample_margin;
        result.warmup_overrun = warmup_overrun;
        result.warmup_bad_len_count = warmup_bad_len_count;
        result.total_overrun = total_overrun;
        result.bad_len_count = bad_len_count;
        result.first_overrun_frame = first_overrun_frame;
        result.elapsed_s = elapsed_s;
        result.capture_mode = char(capture_mode);
        result.tail_needed = tail_needed;
        result.tail_frame_used = double(tail_frame_used);
        result.fail_stage = 'formal';
        result.fail_message = char(formal_fail_message);
        result.frame_log = frame_log;
        return;
    end

    sample_margin = total_len - theoretical_samples;

    % =========================================================
    % pass/fail criteria
    % =========================================================
    if tail_needed == 0
        ok = (warmup_overrun == 0) && ...
             (total_overrun == 0) && ...
             (bad_len_count == 0) && ...
             (total_len == theoretical_samples);
    else
        ok = (warmup_overrun == 0) && ...
             (total_overrun == 0) && ...
             (bad_len_count == 0) && ...
             (total_len >= theoretical_samples);
    end

    % Crop to exactly theoretical_samples when successful
    if ok
        iq = iq_all(1:theoretical_samples);
    else
        iq = iq_all(1:min(total_len, numel(iq_all)));
    end

    timestamp = ts;

    Fs_saved = Fs; %#ok<NASGU>
    Fc_saved = Fc; %#ok<NASGU>
    masterClockRate = sdr.masterClockRate; %#ok<NASGU>
    decimationFactor = sdr.decimationFactor; %#ok<NASGU>
    warmup_frames = sdr.warmup_frames; %#ok<NASGU>
    gain_dB = sdr.gain_dB; %#ok<NASGU>
    outputDataType = sdr.outputDataType; %#ok<NASGU>
    formal_calls_saved = formal_calls; %#ok<NASGU>
    n_full_frames_saved = n_full_frames; %#ok<NASGU>
    tail_needed_saved = tail_needed; %#ok<NASGU>
    tail_frame_used_saved = tail_frame_used; %#ok<NASGU>
    capture_mode_saved = capture_mode; %#ok<NASGU>
    frame_log_saved = frame_log; %#ok<NASGU>

    % =========================================================
    % save only on success
    % =========================================================
    if ok
        save(fullpath, ...
            'iq', ...
            'Fs', ...
            'Fc', ...
            'Fs_saved', ...
            'Fc_saved', ...
            'timestamp', ...
            'capture_time_s', ...
            'theoretical_samples', ...
            'n_full_frames_saved', ...
            'formal_calls_saved', ...
            'tail_needed_saved', ...
            'tail_frame_used_saved', ...
            'capture_mode_saved', ...
            'total_len', ...
            'sample_margin', ...
            'warmup_overrun', ...
            'warmup_bad_len_count', ...
            'total_overrun', ...
            'bad_len_count', ...
            'first_overrun_frame', ...
            'elapsed_s', ...
            'masterClockRate', ...
            'decimationFactor', ...
            'samplesPerFrame', ...
            'warmup_frames', ...
            'gain_dB', ...
            'outputDataType', ...
            'frame_log_saved', ...
            'meta', ...
            '-v7.3');
    else
        filename = "";
        fullpath = "";
    end

    % =========================================================
    % result struct
    % =========================================================
    result = struct();
    result.ok = ok;
    result.filename = char(filename);
    result.fullpath = char(fullpath);
    result.timestamp = char(timestamp);
    result.received_samples = total_len;
    result.theoretical_samples = theoretical_samples;
    result.expected_frames = n_full_frames;
    result.formal_calls = formal_calls;
    result.sample_margin = sample_margin;
    result.warmup_overrun = warmup_overrun;
    result.warmup_bad_len_count = warmup_bad_len_count;
    result.total_overrun = total_overrun;
    result.bad_len_count = bad_len_count;
    result.first_overrun_frame = first_overrun_frame;
    result.elapsed_s = elapsed_s;
    result.capture_mode = char(capture_mode);
    result.tail_needed = tail_needed;
    result.tail_frame_used = double(tail_frame_used);
    result.frame_log = frame_log;
    result.fail_stage = '';
    result.fail_message = '';
end


function v = getMetaField(meta, name, defaultVal)
    if isfield(meta, name)
        v = meta.(name);
    else
        v = defaultVal;
    end
end