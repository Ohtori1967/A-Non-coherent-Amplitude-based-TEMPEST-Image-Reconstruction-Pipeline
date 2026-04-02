function name = pptRemoteFile(c)
%PPTREMOTEFILE Return current PowerPoint file name from remote server.

    resp = ppt_send_cmd(c, "file");
    parts = split(string(resp), " ", 3);

    if numel(parts) >= 3 && parts(1) == "OK" && parts(2) == "file"
        name = strtrim(parts(3));
    else
        error('pptRemoteFile:BadResponse', ...
            'Unexpected response: %s', resp);
    end
end