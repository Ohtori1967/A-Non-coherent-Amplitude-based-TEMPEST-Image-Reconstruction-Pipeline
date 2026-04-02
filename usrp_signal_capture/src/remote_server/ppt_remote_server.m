function ppt_remote_server(port)
%PPT_REMOTE_SERVER Remote control server for PowerPoint on PC1.
%   ppt_remote_server(port) starts a TCP server and listens for remote
%   PowerPoint control commands.
%
%   Supported commands:
%       ping
%       current
%       file
%       next
%       prev
%       goto N
%       quit
%
%   Example:
%       ppt_remote_server(5000)

    if nargin < 1
        port = 5000;
    end

    fprintf('Starting PPT remote server on port %d...\n', port);

    srv = tcpserver("0.0.0.0", port, ...
        "ConnectionChangedFcn", @onConnectionChanged);

    fprintf('Server started.\n');
    fprintf('Waiting for client...\n');
    fprintf('PowerPoint slideshow should already be running on PC1.\n');
    fprintf('Use command "quit" from PC2 to stop the server.\n');
    fprintf('Supported commands: ping, current, file, next, prev, goto N, quit\n\n');

    keepRunning = true;

    while keepRunning
        try
            if srv.NumBytesAvailable > 0
                raw = readline(srv);
                cmd = strtrim(string(raw));

                fprintf('[RX] %s\n', cmd);

                [resp, shouldQuit] = handleCommand(cmd);

                try
                    writeline(srv, resp);
                    fprintf('[TX] %s\n', resp);
                catch MEw
                    warning('ppt_remote_server:WriteFailed', ...
                        'Failed to send response: %s', MEw.message);
                end

                if shouldQuit
                    keepRunning = false;
                end
            end

            pause(0.05);

        catch ME
            warning('ppt_remote_server:LoopError', ...
                'Server loop error: %s', ME.message);

            try
                writeline(srv, "ERR " + string(ME.message));
            catch
            end

            pause(0.1);
        end
    end

    fprintf('\nStopping server...\n');
    clear srv
    fprintf('Server stopped.\n');
end


function [resp, shouldQuit] = handleCommand(cmd)
%HANDLECOMMAND Parse one incoming command.

    shouldQuit = false;
    low = lower(strtrim(cmd));

    if low == "ping"
        resp = "OK pong";
        return;
    end

    if low == "current"
        try
            idx = pptCurrentSlide();
            resp = "OK current " + string(idx);
        catch ME
            resp = "ERR " + simplifyMessage(ME);
        end
        return;
    end

    if low == "file"
        try
            fname = pptCurrentFile();
            resp = "OK file " + string(fname);
        catch ME
            resp = "ERR " + simplifyMessage(ME);
        end
        return;
    end

    if low == "next"
        ok = pptNextSlideSafe();
        if ok
            resp = "OK next";
        else
            resp = "ERR next failed";
        end
        return;
    end

    if low == "prev"
        ok = pptPrevSlideSafe();
        if ok
            resp = "OK prev";
        else
            resp = "ERR prev failed";
        end
        return;
    end

    if startsWith(low, "goto ")
        parts = split(low);
        if numel(parts) ~= 2
            resp = "ERR usage: goto N";
            return;
        end

        n = str2double(parts(2));
        if isnan(n) || n < 1 || floor(n) ~= n
            resp = "ERR invalid slide number";
            return;
        end

        try
            pptGotoSlide(n);
            resp = "OK goto " + string(n);
        catch ME
            resp = "ERR " + simplifyMessage(ME);
        end
        return;
    end

    if low == "quit"
        resp = "OK quit";
        shouldQuit = true;
        return;
    end

    resp = "ERR unknown command";
end


function msg = simplifyMessage(ME)
%SIMPLIFYMESSAGE Return a compact one-line message from MException.

    msg = string(ME.message);
    msg = replace(msg, newline, " ");
    msg = strtrim(msg);
end


function onConnectionChanged(src, ~)
%ONCONNECTIONCHANGED Display connection state changes.

    try
        if src.Connected
            fprintf('[INFO] Client connected.\n');
        else
            fprintf('[INFO] Client disconnected.\n');
        end
    catch
        fprintf('[INFO] Connection state changed.\n');
    end
end