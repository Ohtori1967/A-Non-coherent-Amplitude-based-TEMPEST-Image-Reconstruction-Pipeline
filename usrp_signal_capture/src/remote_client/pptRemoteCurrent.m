function idx = pptRemoteCurrent(c)
%PPTREMOTECURRENT Return current slide index from remote PPT.

    resp = ppt_send_cmd(c, "current");
    parts = split(string(resp));

    if numel(parts) >= 3 && parts(1) == "OK" && parts(2) == "current"
        idx = str2double(parts(3));
        if isnan(idx)
            error('pptRemoteCurrent:ParseFailed', ...
                'Failed to parse slide index from response: %s', resp);
        end
    else
        error('pptRemoteCurrent:BadResponse', ...
            'Unexpected response: %s', resp);
    end
end