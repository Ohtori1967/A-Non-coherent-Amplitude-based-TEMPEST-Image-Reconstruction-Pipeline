clear; clc;

% =====================================
% X310 正式采样并保存为 .mat
% =====================================

ip_addr = '192.168.40.2';

Fc = 742.5e6;              % 频点
capture_time_s = 0.2;      % 录制时长
gain_dB = 15;              % 增益（按你的实际情况调整）

masterClockRate = 184.32e6;
decimationFactor = 3;
Fs = masterClockRate / decimationFactor;   % 61.44 MSPS

samplesPerFrame = 16000;   % 已验证稳定
warmup_frames = 20;

theoretical_samples = round(Fs * capture_time_s);

ts = string(datetime('now','Format','yyyyMMdd_HHmmss'));
mat_filename = sprintf( ...
    'x310_%s_CF_%.3fMHz_FS_%.3fMSPS_T%.1fs.mat', ...
    ts, Fc/1e6, Fs/1e6, capture_time_s);

disp("Output file: " + mat_filename);

fprintf('=============================================\n');
fprintf('X310 capture to MAT\n');
fprintf('IP Address          : %s\n', ip_addr);
fprintf('Center Frequency    : %.3f MHz\n', Fc/1e6);
fprintf('MasterClockRate     : %.3f MHz\n', masterClockRate/1e6);
fprintf('DecimationFactor    : %d\n', decimationFactor);
fprintf('Sampling Rate       : %.3f MSPS\n', Fs/1e6);
fprintf('Capture Time        : %.3f s\n', capture_time_s);
fprintf('SamplesPerFrame     : %d\n', samplesPerFrame);
fprintf('Warm-up Frames      : %d\n', warmup_frames);
fprintf('Target Samples      : %d\n', theoretical_samples);
fprintf('=============================================\n\n');

% =====================================
% 创建接收对象
% =====================================
rx = comm.SDRuReceiver( ...
    'Platform', 'X310', ...
    'IPAddress', ip_addr, ...
    'CenterFrequency', Fc, ...
    'MasterClockRate', masterClockRate, ...
    'DecimationFactor', decimationFactor, ...
    'Gain', gain_dB, ...
    'SamplesPerFrame', samplesPerFrame, ...
    'OutputDataType', 'single');

% =====================================
% Warm-up
% =====================================
warmup_overrun = 0;
fprintf('Warm-up ...\n');
for k = 1:warmup_frames
    [~, ~, ov] = rx();
    warmup_overrun = warmup_overrun + double(ov);
end
fprintf('Warm-up overruns: %d\n', warmup_overrun);

% =====================================
% 正式采样
% =====================================
fprintf('Recording ...\n');

numFramesNeeded = ceil(theoretical_samples / samplesPerFrame);

% 预分配：按 frame 拼接
iq_all = complex(zeros(numFramesNeeded * samplesPerFrame, 1, 'single'));

write_idx = 1;
total_len = 0;
total_overrun = 0;

tic;
for k = 1:numFramesNeeded
    [x, len, overrun] = rx();

    len = double(len);
    total_overrun = total_overrun + double(overrun);

    if len > 0
        iq_all(write_idx:write_idx+len-1) = x(1:len);
        write_idx = write_idx + len;
        total_len = total_len + len;
    end
end
elapsed_s = toc;

release(rx);
clear rx;

% 截断到实际收到的长度
iq_all = iq_all(1:total_len);

% 再截断到理论长度（若超出）
if total_len >= theoretical_samples
    iq = iq_all(1:theoretical_samples);
else
    iq = iq_all;   % 理论上如果稳定通过，不应发生
end

sample_margin = total_len - theoretical_samples;

fprintf('Done.\n');
fprintf('Received Samples : %d\n', total_len);
fprintf('Sample Margin    : %+d\n', sample_margin);
fprintf('Total Overruns   : %d\n', total_overrun);
fprintf('Elapsed Time     : %.4f s\n', elapsed_s);

% =====================================
% 保存为 .mat
% =====================================
timestamp = ts;

save(mat_filename, ...
    'iq', ...
    'Fs', ...
    'Fc', ...
    'gain_dB', ...
    'masterClockRate', ...
    'decimationFactor', ...
    'samplesPerFrame', ...
    'capture_time_s', ...
    'theoretical_samples', ...
    'total_len', ...
    'sample_margin', ...
    'total_overrun', ...
    'warmup_frames', ...
    'warmup_overrun', ...
    'timestamp', ...
    '-v7.3');

fprintf('Saved to %s\n', mat_filename);