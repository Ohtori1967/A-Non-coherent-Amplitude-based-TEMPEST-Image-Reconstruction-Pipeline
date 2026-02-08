% ===============================================================
%   Convert first 0.1s (≈6M samples) of .bb to .mat for Python
% ===============================================================

clear; clc;

% ===== inputfile =====
bb_file = './bb_20260206_120157_CF_742.500MHz_FS_60.000MSPS_T0.5s.bb';

Fs      = 60e6;          
Tsec    = 0.1;            % only use 0.1 sec
N_samps = round(Fs * Tsec);   
frmLen  = 1024*1024;    
out_mat = strrep(bb_file, '.bb', sprintf('_%.1fs.mat', Tsec));

r = comm.BasebandFileReader(bb_file, 'SamplesPerFrame', frmLen);
fprintf('[Reader] SampleRate = %.1f MHz, CenterFreq = %.1f MHz\n', ...
        r.SampleRate/1e6, r.CenterFrequency/1e6);

x = complex(zeros(N_samps,1,'single'));
ptr = 1;

fprintf('Reading first %.1f s (≈%.1f M samples)...\n', Tsec, N_samps/1e6);
tic;
while ~isDone(r) && ptr <= N_samps
    y = r();
    n = numel(y);
    if ptr + n - 1 > N_samps
        y = y(1 : N_samps - ptr + 1);
        n = numel(y);
    end
    x(ptr:ptr+n-1) = y;
    ptr = ptr + n;
end
release(r);
toc;

fprintf('Actually read %.2f M samples.\n', (ptr-1)/1e6);

save(out_mat, 'x', '-v7.3');
fprintf('Saved to "%s" (≈%.1f MB)\n', out_mat, numel(x)*8/1e6);
