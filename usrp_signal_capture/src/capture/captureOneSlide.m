function result = captureOneSlide(cfg, client, rx, slideMeta, sample_id)
%CAPTUREONESLIDE Jump to one slide, confirm it, then capture.

    arguments
        cfg struct
        client
        rx
        slideMeta struct
        sample_id (1,1) double
    end

    targetSlide = slideMeta.slide_index;

    % ---------- jump to target slide ----------
    pptRemoteGoto(client, targetSlide);
    pause(cfg.ppt.settle_time_s);

    % ---------- confirm current slide ----------
    currentSlide = pptRemoteCurrent(client);
    if currentSlide ~= targetSlide
        error('captureOneSlide:SlideMismatch', ...
            'Expected slide %d, but current slide is %d.', ...
            targetSlide, currentSlide);
    end

    % ---------- get PPT filename ----------
    ppt_filename = "";
    try
        ppt_filename = pptRemoteFile(client);
    catch
        if isfield(cfg.ppt, 'filename_fallback')
            ppt_filename = string(cfg.ppt.filename_fallback);
        end
    end

    % ---------- optional pause right before capture ----------
    if isfield(cfg.general, 'pause_before_capture_s') && cfg.general.pause_before_capture_s > 0
        pause(cfg.general.pause_before_capture_s);
    end

    % ---------- merge metadata ----------
    meta = slideMeta;
    meta.sample_id = sample_id;
    meta.slide_index = targetSlide;
    meta.confirmed_slide_index = currentSlide;
    meta.ppt_filename = char(ppt_filename);

    % ----- display/content -----
    meta.content_type = char(cfg.meta_common.content_type);
    meta.font_name = char(cfg.meta_common.font_name);
    meta.font_size_pt = cfg.meta_common.font_size_pt;
    meta.theme = char(cfg.meta_common.theme);
    meta.batch_notes = char(cfg.meta_common.notes);

    % ----- hardware / experiment setup -----
    meta.sdr_model = char(cfg.meta_common.sdr_model);
    meta.antenna_model = char(cfg.meta_common.antenna_model);
    meta.test_distance_cm = cfg.meta_common.test_distance_cm;
    meta.environment = char(cfg.meta_common.environment);

    % ----- monitor/display info -----
    meta.monitor_model = char(cfg.meta_common.monitor_model);
    meta.monitor_resolution = char(cfg.meta_common.monitor_resolution);
    meta.monitor_refresh_hz = cfg.meta_common.monitor_refresh_hz;

    % ---------- capture ----------
    result = x310CaptureOnce(cfg, rx, cfg.general.out_dir, meta);

    % ---------- attach summary fields for log ----------
    result.sample_id = sample_id;
    result.slide_index = targetSlide;
    result.content_id = getSlideField(slideMeta, 'content_id', "");
    result.content_type = char(cfg.meta_common.content_type);
    result.font_name = char(cfg.meta_common.font_name);
    result.font_size_pt = cfg.meta_common.font_size_pt;
    result.theme = char(cfg.meta_common.theme);
    result.notes = getSlideField(slideMeta, 'notes', "");
    result.batch_notes = char(cfg.meta_common.notes);
    result.ppt_filename = char(ppt_filename);

    result.sdr_model = char(cfg.meta_common.sdr_model);
    result.antenna_model = char(cfg.meta_common.antenna_model);
    result.test_distance_cm = cfg.meta_common.test_distance_cm;
    result.environment = char(cfg.meta_common.environment);

    result.monitor_model = char(cfg.meta_common.monitor_model);
    result.monitor_resolution = char(cfg.meta_common.monitor_resolution);
    result.monitor_refresh_hz = cfg.meta_common.monitor_refresh_hz;
end


function v = getSlideField(s, name, defaultVal)
    if isfield(s, name)
        v = s.(name);
    else
        v = defaultVal;
    end
end