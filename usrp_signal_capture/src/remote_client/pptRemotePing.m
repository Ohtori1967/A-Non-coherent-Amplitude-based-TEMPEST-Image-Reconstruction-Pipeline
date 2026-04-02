function resp = pptRemotePing(c)
%PPTREMOTEPING Ping the remote PPT server.
    resp = ppt_send_cmd(c, "ping");
end