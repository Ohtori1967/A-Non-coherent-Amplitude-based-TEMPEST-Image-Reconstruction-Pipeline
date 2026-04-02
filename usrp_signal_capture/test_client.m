c = ppt_remote_client("192.168.43.144", 5000);

pptRemotePing(c)
idx = pptRemoteCurrent(c)
pptRemoteNext(c)
pptRemotePrev(c)
pptRemoteGoto(c, 3)

ppt_remote_cli(c)