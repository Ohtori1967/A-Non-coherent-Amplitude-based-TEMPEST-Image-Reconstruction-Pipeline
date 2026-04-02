function slideList = buildSlideList(cfg)
%BUILDSLIDELIST Build slide list for batch capture.

    if ~cfg.slide_setup.use_auto_range
        slideList = cfg.slides_manual;
        return;
    end

    idxs = cfg.slide_setup.slide_range;
    n = numel(idxs);

    slideList = repmat(struct( ...
        'slide_index', NaN, ...
        'content_id', "", ...
        'notes', "" ...
    ), n, 1);

    for k = 1:n
        s = idxs(k);
        slideList(k).slide_index = s;
        slideList(k).content_id = sprintf('slide%03d', s);
        slideList(k).notes = sprintf('auto-generated metadata for slide %d', s);
    end
end