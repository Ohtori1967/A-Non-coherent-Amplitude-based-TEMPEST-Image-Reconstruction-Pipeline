%% =====================================================
%  TEMPEST Image Quality Evaluation
%  Metrics: PSNR & SSIM
% =====================================================

clear; clc;

%% ===== Input img path =====
img_ref_path = './img/p1.png';   % img_original

img_am_path = './img/p1_rec.png';     % img_recovered 

%% ===== read img =====
img_ref = imread(img_ref_path);
img_am  = imread(img_am_path);

%% ===== rgb2grayscale =====
if ndims(img_ref) == 3
    img_ref = rgb2gray(img_ref);
end

if ndims(img_am) == 3
    img_am = rgb2gray(img_am);
end

img_ref = im2double(img_ref);
img_am  = im2double(img_am);

assert(isequal(size(img_ref), size(img_am)), ...
    'Error: Image sizes do not match.');

%% ===== PSNR =====
psnr_val = psnr(img_am, img_ref);

%% ===== SSIM =====
ssim_val = ssim(img_am, img_ref);

%% ===== Results output =====
fprintf('===== TEMPEST Image Quality Metrics =====\n');
fprintf('PSNR : %.2f dB\n', psnr_val);
fprintf('SSIM : %.4f\n', ssim_val);
fprintf('========================================\n');
