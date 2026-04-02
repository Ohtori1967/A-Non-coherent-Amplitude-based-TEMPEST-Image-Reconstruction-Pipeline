function ppt_remote_cli(c)
%PPT_REMOTE_CLI Interactive command-line remote control for PowerPoint.
%
%   ppt_remote_cli(c)
%
%   Supported input examples:
%       ping
%       current
%       next
%       prev
%       goto 5
%       quit
%       exit   % only exit local CLI, does not stop server

    if nargin < 1
        error('ppt_remote_cli:MissingClient', ...
            'Usage: ppt_remote_cli(client)');
    end

    fprintf('\nRemote PPT CLI started.\n');
    fprintf('Commands:\n');
    fprintf('  ping\n');
    fprintf('  current\n');
    fprintf('  next\n');
    fprintf('  prev\n');
    fprintf('  goto N\n');
    fprintf('  quit   (stop remote server)\n');
    fprintf('  exit   (leave this local CLI only)\n\n');

    while true
        cmd = strtrim(input('ppt-remote> ', 's'));

        if isempty(cmd)
            continue;
        end

        if strcmpi(cmd, 'exit')
            fprintf('Leaving local CLI.\n');
            break;
        end

        try
            resp = ppt_send_cmd(c, cmd);
            disp(resp);

            if strcmpi(strtrim(cmd), 'quit')
                fprintf('Remote server requested to stop.\n');
                break;
            end

        catch ME
            fprintf('Error: %s\n', ME.message);
        end
    end
end