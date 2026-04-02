function resp = ppt_send_cmd(client, cmd)
%PPT_SEND_CMD Send one command to the remote server and wait for response.
%
%   resp = ppt_send_cmd(client, "next")

    if nargin < 2
        error('ppt_send_cmd:MissingInput', ...
            'Usage: ppt_send_cmd(client, cmd)');
    end

    cmd = string(cmd);
    writeline(client, cmd);

    t0 = tic;
    while client.NumBytesAvailable == 0
        pause(0.01);
        if toc(t0) > 3
            error('ppt_send_cmd:Timeout', 'No response from server.');
        end
    end

    resp = strtrim(string(readline(client)));
    fprintf('[SERVER] %s\n', resp);
end