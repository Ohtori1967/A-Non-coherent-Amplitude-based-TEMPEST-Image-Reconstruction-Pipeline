function resp = pptRemotePrev(c)
%PPTREMOTEPREV Go to previous slide remotely.
    resp = ppt_send_cmd(c, "prev");
end