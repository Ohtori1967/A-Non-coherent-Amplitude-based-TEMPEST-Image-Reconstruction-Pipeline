function result = x310CaptureOnce(cfg, rx, outDir, meta)
%X310CAPTUREONCE Capture one IQ record from an existing X310 rx object.
% Supports both exact-multiple and non-multiple SamplesPerFrame cases.
% Save MAT only when capture passes acceptance criteria.
%
% Warm-up behavior:
%   - if cfg.sdr.use_warmup == true, run warm-up for cfg.sdr.warmup_frames
%   - if cfg.sdr.use_warmup == false, skip warm-up completely
%
% Prime-frame behavior:
%   - if cfg.sdr.use_prime_frames == true, read cfg.sdr.prime_frames frames
%   - these frames are discarded and do NOT participate in pass/fail metrics
%   - if cfg.sdr.prime_only_on_first_attempt == true, only attempt #1 uses prime

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
    attempt_idx = getMetaField(meta, 'attempt_idx', 1);

    filename = sprintf( ...
        'sample_%03d_slide%03d_CF_%.3fMHz_FS_%.3fMSPS_T%.1fs_%s.mat', ...
        sample_id, slide_index, Fc/1e6, Fs/1e6, capture_time_s, ts);

    fullpath = fullfile(outDir, filename);

    % =========================================================
    % warm-up
    % =========================================================
    use_warmup = false;
    if isfield(sdr, 'use_warmup')
        use_warmup = logical(sdr.use_warmup);
    end

    configured_warmup_frames = 0;
    if isfield(sdr, 'warmup_frames')
        configured_warmup_frames = sdr.warmup_frames;
    end

    if use_warmup
        warmup_frames_to_run = configured_warmup_frames;
    else
        warmup_frames_to_run = 0;
    end

    warmup_overrun = 0;
    warmup_bad_len_count = 0;
    warmup_ok = true;
    warmup_fail_message = "";

    for k = 1:warmup_frames_to_run
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
        result.use_warmup = use_warmup;
        result.warmup_frames_requested = configured_warmup_frames;
        result.warmup_frames_run = warmup_frames_to_run;
        result.use_prime_frames = false;
        result.prime_frames_requested = 0;
        result.prime_frames_run = 0;
        result.fail_stage = 'warmup';
        result.fail_message = char(warmup_fail_message);
        return;
    end

    % =========================================================
    % prime frames (discard only)
    % =========================================================
    use_prime_frames = false;
    if isfield(sdr, 'use_prime_frames')
        use_prime_frames = logical(sdr.use_prime_frames);
    end

    configured_prime_frames = 0;
    if isfield(sdr, 'prime_frames')
        configured_prime_frames = sdr.prime_frames;
    end

    prime_only_on_first_attempt = false;
    if isfield(sdr, 'prime_only_on_first_attempt')
        prime_only_on_first_attempt = logical(sdr.prime_only_on_first_attempt);
    end

    if prime_only_on_first_attempt && attempt_idx ~= 1
        use_prime_frames = false;
    end

    if use_prime_frames
        prime_frames_to_run = configured_prime_frames;
    else
        prime_frames_to_run = 0;
    end

    prime_ok = true;
    prime_fail_message = "";

    for k = 1:prime_frames_to_run
        try
            rx();
        catch ME
            prime_ok = false;
            prime_fail_message = string(ME.message);
            break;
        end
    end

    if ~prime_ok
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
        result.use_warmup = use_warmup;
        result.warmup_frames_requested = configured_warmup_frames;
        result.warmup_frames_run = warmup_frames_to_run;
        result.use_prime_frames = use_prime_frames;
        result.prime_frames_requested = configured_prime_frames;
        result.prime_frames_run = prime_frames_to_run;
        result.fail_stage = 'prime';
        result.fail_message = char(prime_fail_message);
        return;
    end

    % =========================================================
    % formal capture
    % =========================================================
    alloc_len = formal_calls * samplesPerFrame;
    iq_all = complex(zeros(alloc_len, 1, sdr.outputDataType));

    write_idx = 1;
    total_len = 0;
    total_overrun = 0;
    bad_len_count = 0;
    first_overrun_frame = NaN;
    formal_ok = true;
    formal_fail_message = "";

    frame_log = zeros(formal_calls, 4);

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
        result.frame_log = frame_log;
        result.use_warmup = use_warmup;
        result.warmup_frames_requested = configured_warmup_frames;
        result.warmup_frames_run = warmup_frames_to_run;
        result.use_prime_frames = use_prime_frames;
        result.prime_frames_requested = configured_prime_frames;
        result.prime_frames_run = prime_frames_to_run;
        result.fail_stage = 'formal';
        result.fail_message = char(formal_fail_message);
        return;
    end

    sample_margin = total_len - theoretical_samples;

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
    gain_dB = sdr.gain_dB; %#ok<NASGU>
    outputDataType = sdr.outputDataType; %#ok<NASGU>
    formal_calls_saved = formal_calls; %#ok<NASGU>
    n_full_frames_saved = n_full_frames; %#ok<NASGU>
    tail_needed_saved = tail_needed; %#ok<NASGU>
    tail_frame_used_saved = tail_frame_used; %#ok<NASGU>
    capture_mode_saved = capture_mode; %#ok<NASGU>
    frame_log_saved = frame_log; %#ok<NASGU>
    use_warmup_saved = use_warmup; %#ok<NASGU>
    warmup_frames_requested_saved = configured_warmup_frames; %#ok<NASGU>
    warmup_frames_run_saved = warmup_frames_to_run; %#ok<NASGU>
    use_prime_frames_saved = use_prime_frames; %#ok<NASGU>
    prime_frames_requested_saved = configured_prime_frames; %#ok<NASGU>
    prime_frames_run_saved = prime_frames_to_run; %#ok<NASGU>

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
            'gain_dB', ...
            'outputDataType', ...
            'frame_log_saved', ...
            'use_warmup_saved', ...
            'warmup_frames_requested_saved', ...
            'warmup_frames_run_saved', ...
            'use_prime_frames_saved', ...
            'prime_frames_requested_saved', ...
            'prime_frames_run_saved', ...
            'meta', ...
            '-v7.3');
    else
        filename = "";
        fullpath = "";
    end

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
    result.use_warmup = use_warmup;
    result.warmup_frames_requested = configured_warmup_frames;
    result.warmup_frames_run = warmup_frames_to_run;
    result.use_prime_frames = use_prime_frames;
    result.prime_frames_requested = configured_prime_frames;
    result.prime_frames_run = prime_frames_to_run;
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
