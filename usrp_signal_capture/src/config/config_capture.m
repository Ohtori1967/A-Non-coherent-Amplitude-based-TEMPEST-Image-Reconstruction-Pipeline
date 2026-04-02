function cfg = config_capture()
%CONFIG_CAPTURE Configuration for PPT + X310 batch capture.

    % =========================
    % General
    % =========================
    cfg.general.out_root = fullfile(pwd, 'outputs');
    cfg.general.out_dir = "";              % filled at runtime
    cfg.general.checkpoint_dir = "";       % filled at runtime
    cfg.general.final_log_csv = "";        % filled at runtime

    cfg.general.retry_max = 5;
    cfg.general.checkpoint_every = 10;

    % pause between attempts (after one attempt ends, before next attempt)
    cfg.general.pause_between_attempts_s = 0.2;

    % additional pause right before formal capture
    cfg.general.pause_before_capture_s = 0.2;

    % Resume options
    cfg.general.resume_if_possible = true;
    cfg.general.resume_existing_out_dir = "";

    % =========================
    % PPT remote
    % =========================
    cfg.ppt.server_ip = "192.168.43.144";
    cfg.ppt.server_port = 5000;

    % wait after goto, for display content to settle
    cfg.ppt.settle_time_s = 0.35;

    cfg.ppt.filename_fallback = "your_slides.pptx";

    % =========================
    % SDR / X310
    % =========================
    cfg.sdr.ip_addr = '192.168.40.2';
    cfg.sdr.fc = 742.5e6;
    cfg.sdr.gain_dB = 20;

    cfg.sdr.masterClockRate = 184.32e6;
    cfg.sdr.decimationFactor = 3;
    cfg.sdr.capture_time_s = 0.2;

    % IMPORTANT:
    % Keep these aligned with the overrun test that actually passed.
    cfg.sdr.samplesPerFrame = 24000;
    cfg.sdr.warmup_frames = 60;

    cfg.sdr.outputDataType = 'single';
    cfg.sdr.fs = cfg.sdr.masterClockRate / cfg.sdr.decimationFactor;

    % =========================
    % Batch-level metadata
    % =========================
    cfg.meta_common.content_type = "text";
    cfg.meta_common.font_name = "Times New Roman";
    cfg.meta_common.font_size_pt = 20;
    cfg.meta_common.theme = "light";
    cfg.meta_common.notes = "uniform settings for all slides in this batch";

    cfg.meta_common.sdr_model = "USRP X310";
    cfg.meta_common.antenna_model = "HTOOL HT8";
    cfg.meta_common.test_distance_cm = 10;
    cfg.meta_common.environment = "Meeting Room";

    cfg.meta_common.monitor_model = "DELL C6522QT";
    cfg.meta_common.monitor_resolution = "1920x1080";
    cfg.meta_common.monitor_refresh_hz = 60;

    % =========================
    % Slide setup
    % =========================
    cfg.slide_setup.use_auto_range = true;
    cfg.slide_setup.slide_range = 1:100;

    % =========================
    % Optional manual slide metadata
    % =========================
    cfg.slides_manual = struct( ...
        'slide_index', {1, 2, 3}, ...
        'content_id',  {'slide001', 'slide002', 'slide003'}, ...
        'notes',       {'page1', 'page2', 'page3'} ...
    );
end