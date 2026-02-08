%% =====================================================
%  TEMPEST Batch Evaluation
%  Metrics: PSNR (via averaged MSE) & SSIM
% =====================================================

clear; clc;

%% ===== 参数 =====
data_dir = './reconstruct';
num_imgs = 5;              % 图像组数（img1 ~ img5）
cases = {'origin', 'am', 'pm', 'am_pm'};
num_cases = numel(cases);

%% ===== 结果存储 =====
MSE_all  = zeros(num_imgs, num_cases);
SSIM_all = zeros(num_imgs, num_cases);

%% ===== 主循环 =====
for i = 1:num_imgs
    % --- 读取参考图 ---
    ref_path = fullfile(data_dir, sprintf('img%d_origin.png', i));
    R = imread(ref_path);
    if ndims(R) == 3, R = rgb2gray(R); end
    R = im2double(R);

    for c = 1:num_cases
        case_name = cases{c};
        img_path = fullfile(data_dir, sprintf('img%d_%s.png', i, case_name));

        I = imread(img_path);
        if ndims(I) == 3, I = rgb2gray(I); end
        I = im2double(I);

        assert(isequal(size(R), size(I)), ...
            'Size mismatch: img%d_%s.png', i, case_name);

        % --- 计算 MSE ---
        diff = I - R;
        MSE_all(i, c) = mean(diff(:).^2);

        % --- 计算 SSIM ---
        SSIM_all(i, c) = ssim(I, R);
    end
end

%% ===== PSNR：先平均 MSE，再转 dB =====
MAXI = 1.0;  % 图像已归一化到 [0,1]
MSE_mean = mean(MSE_all, 1);
PSNR_mean = 10 * log10(MAXI^2 ./ MSE_mean);

%% ===== 标准差 =====
% PSNR 的 std 基于逐图 PSNR（用于展示离散程度）
PSNR_each = 10 * log10(MAXI^2 ./ MSE_all);
PSNR_std  = std(PSNR_each, 0, 1);

SSIM_mean = mean(SSIM_all, 1);
SSIM_std  = std(SSIM_all, 0, 1);

%% ===== 输出结果 =====
fprintf('\n===== TEMPEST Evaluation Results (Mean ± Std) =====\n');
for c = 1:num_cases
    fprintf('%-8s : PSNR = %.2f ± %.2f dB | SSIM = %.4f ± %.4f\n', ...
        cases{c}, PSNR_mean(c), PSNR_std(c), ...
        SSIM_mean(c), SSIM_std(c));
end
fprintf('==================================================\n');
