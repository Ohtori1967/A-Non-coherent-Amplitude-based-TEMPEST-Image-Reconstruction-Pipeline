function client = ppt_remote_client(serverIP, port)
%PPT_REMOTE_CLIENT Connect to PPT remote server on PC1.
%
%   client = ppt_remote_client("192.168.43.144", 5000)

    if nargin < 1 || strlength(string(serverIP)) == 0
        error('ppt_remote_client:MissingIP', ...
            'You must provide server IP.');
    end

    if nargin < 2
        port = 5000;
    end

    client = tcpclient(serverIP, port, "Timeout", 3);
    fprintf('Connected to %s:%d\n', serverIP, port);
end