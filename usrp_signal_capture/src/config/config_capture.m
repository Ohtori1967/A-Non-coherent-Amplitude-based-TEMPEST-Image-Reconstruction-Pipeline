function cfg = config_capture()
%CONFIG_CAPTURE Configuration for PPT + X310 batch capture.

    % =========================================================
    % General
    % =========================================================
    cfg.general.out_root = fullfile(pwd, 'outputs');
    cfg.general.out_dir = "";              % filled at runtime
    cfg.general.checkpoint_dir = "";       % filled at runtime
    cfg.general.final_log_csv = "";        % filled at runtime

    cfg.general.retry_max = 6;
    cfg.general.checkpoint_every = 5;

    % Pause between attempts
    cfg.general.pause_between_attempts_s = 0.5;

    % Pause right before formal capture
    cfg.general.pause_before_capture_s = 0.5;

    % Resume options
    cfg.general.resume_if_possible = true;
    cfg.general.resume_existing_out_dir = ...
        "E:\UsersData\Desktop\usrp_signal_capture\outputs\output_16x9_20pt_pages_1001-1100_CF_742.500MHz_FS_61.440MSPS_20260405_191603";

    % If true, delete stale sample artifacts whose sample_id >= nextSampleId
    % before resuming capture.
    cfg.general.cleanup_uncheckpointed_samples = true;

    % =========================================================
    % PPT remote
    % =========================================================
    cfg.ppt.server_ip = "192.168.43.144"; %192.168.43.144
    cfg.ppt.server_port = 5000;
    cfg.ppt.settle_time_s = 0.35;
    cfg.ppt.filename_fallback = "your_slides.pptx";

    % =========================================================
    % SDR / X310
    % =========================================================
    cfg.sdr.ip_addr = '192.168.40.2';
    cfg.sdr.fc = 742.5e6;
    cfg.sdr.gain_dB = 20;

    cfg.sdr.masterClockRate = 184.32e6;
    cfg.sdr.decimationFactor = 3;
    cfg.sdr.fs = cfg.sdr.masterClockRate / cfg.sdr.decimationFactor;

    cfg.sdr.capture_time_s = 0.2;
    cfg.sdr.samplesPerFrame = 96000;
    cfg.sdr.outputDataType = 'single';

    % -------------------------
    % Warm-up control
    % -------------------------
    cfg.sdr.use_warmup = false;
    cfg.sdr.warmup_frames = 0;

    % -------------------------
    % Prime-frame control
    % -------------------------
    cfg.sdr.use_prime_frames = true;
    cfg.sdr.prime_frames = 1;
    cfg.sdr.prime_only_on_first_attempt = true;

    % =========================================================
    % RX lifecycle / stabilization
    % =========================================================
    cfg.sdr.pause_after_rx_create_s = 0.5;
    cfg.sdr.pause_before_rx_recreate_s = 0.5;

    % Ordinary fail threshold
    cfg.sdr.fail_recreate_threshold = 1;

    % First-attempt transient rule
    cfg.sdr.enable_first_attempt_transient_mode = true;
    cfg.sdr.first_attempt_expect_total_overrun = 1;
    cfg.sdr.first_attempt_expect_bad_len = 1;
    cfg.sdr.first_attempt_expect_warmup_overrun = 0;
    cfg.sdr.first_attempt_expect_warmup_bad_len = 0;

    % =========================================================
    % Progress display
    % =========================================================
    cfg.display.show_progress_bar = true;
    cfg.display.progress_bar_width = 28;

    % =========================================================
    % Batch-level metadata
    % =========================================================
    cfg.meta_common.content_type = "text";
    cfg.meta_common.font_name = "Times New Roman";
    cfg.meta_common.font_size_pt = 10;
    cfg.meta_common.theme = "light";
    cfg.meta_common.notes = "uniform settings for all slides in this batch";

    cfg.meta_common.sdr_model = "USRP X310";
    cfg.meta_common.antenna_model = "HTOOL HT8";
    cfg.meta_common.test_distance_cm = 20;
    cfg.meta_common.environment = "Meeting Room";

    cfg.meta_common.monitor_model = "DELL C6522QT";
    cfg.meta_common.monitor_resolution = "1920x1080";
    cfg.meta_common.monitor_refresh_hz = 60;

    % =========================================================
    % Slide setup
    % =========================================================
    cfg.slide_setup.use_auto_range = true;
    cfg.slide_setup.slide_range = 1:100;

    % =========================================================
    % Optional manual slide metadata
    % =========================================================
    cfg.slides_manual = struct( ...
        'slide_index', {1, 2, 3}, ...
        'content_id',  {'slide001', 'slide002', 'slide003'}, ...
        'notes',       {'page1', 'page2', 'page3'} ...
    );
end
