configurePlutoRadio('AD9364');

ip        = 'ip:192.168.10.1';
Fs        = 60e6;                
Fc        = 742.5e6;             % fc
Tsec      = 0.5;                 % recording time
SampsFrm  = 1024*1024;           
% gain_dB   = 25;                  % gain
gain_dB   = 0;

ts = string(datetime('now','Format','yyyyMMdd_HHmmss'));
bb_filename = sprintf('bb_%s_CF_%.3fMHz_FS_%.3fMSPS_T%.1fs.bb', ...
    ts, Fc/1e6, Fs/1e6, Tsec);
disp("Output file: " + bb_filename);

rx = sdrrx('Pluto', ...
    'RadioID',            ip, ...
    'CenterFrequency',    Fc, ...
    'BasebandSampleRate', Fs, ...
    'SamplesPerFrame',    SampsFrm, ...
    'GainSource',         'Manual', ...
    'Gain',               gain_dB, ...
    'OutputDataType',     'single', ...
    'ShowAdvancedProperties', true);

% Bandwidth
rfBW = 8e6;
okBW = false;
try
    rx.RFBandwidth = rfBW; okBW = true;
catch
    try, setFilter(rx, rx.BasebandSampleRate, rfBW); okBW = true; end
    if ~okBW
        try, designCustomFilter(rx, rx.BasebandSampleRate, rfBW); okBW = true; end
    end
end
if okBW
    fprintf('[RX] RF bandwidth set to ~%.1f MHz\n', rfBW/1e6);
else
    fprintf('[RX] RF bandwidth unchanged (fallback to digital LPF later)\n');
end

% Sampling
framesNeeded = ceil((Fs*Tsec)/SampsFrm);

writer = comm.BasebandFileWriter(bb_filename, Fs, Fc);
disp('Recording ...');
for k = 1:framesNeeded
    x = rx();            
    writer(x);
end
release(writer); release(rx);

totalSamples = framesNeeded*SampsFrm;
fprintf('Done. Saved ≈ %.2f M samples (≈ %.2f s)\n', totalSamples/1e6, totalSamples/Fs);
