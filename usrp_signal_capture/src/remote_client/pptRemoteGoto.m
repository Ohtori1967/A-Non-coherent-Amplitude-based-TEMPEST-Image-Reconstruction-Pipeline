function resp = pptRemoteGoto(c, n)
%PPTREMOTEGOTO Jump to a specific slide remotely.

    if ~isscalar(n) || ~isnumeric(n) || isnan(n) || n < 1 || floor(n) ~= n
        error('pptRemoteGoto:InvalidInput', ...
            'Slide number must be a positive integer.');
    end

    resp = ppt_send_cmd(c, sprintf('goto %d', n));
end