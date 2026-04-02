function resp = pptRemoteNext(c)
%PPTREMOTENEXT Advance to next slide remotely.
    resp = ppt_send_cmd(c, "next");
end