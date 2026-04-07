from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np
import pandas as pd
from scipy.ndimage import gaussian_filter, gaussian_filter1d
from scipy.signal import find_peaks
from sklearn.linear_model import LinearRegression, RANSACRegressor
from tqdm.auto import tqdm


DEFAULT_SHEAR_PARAMS: dict[str, Any] = {
    "blur_sigma": 1.0,
    "row_resp_smooth_sigma": 3.0,
    "min_peak_distance_ratio": 0.08,
    "min_peak_prominence_ratio": 0.15,
    "min_block_h_ratio": 0.08,
    "search_x_min_ratio": 0.02,
    "search_x_max_ratio": 0.98,
    "contrast_win": 6,
    "row_margin": 6,
    "topk_each_polarity": 2,
    "row_score_grad_w": 1.0,
    "row_score_contrast_w": 0.8,
    "min_local_peak_distance": 5,
    "block_y_margin_ratio": 0.04,
    "row_step": 2,
    "min_points_for_fit": 30,
    "min_inliers": 20,
    "ransac_residual_threshold": 3.0,
    "ransac_max_trials": 200,
    "max_lines_per_block": 1,
    "line_rank_rmse_w": 2.0,
    "line_rank_side_w": 20.0,
}


def read_gray01(path: str | Path) -> np.ndarray:
    img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise FileNotFoundError(path)
    return img.astype(np.float32) / 255.0


def compute_smoothed_and_gradients(img: np.ndarray, blur_sigma: float = 1.0):
    img_sm = gaussian_filter(img, sigma=blur_sigma)
    gx = cv2.Sobel(img_sm, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(img_sm, cv2.CV_32F, 0, 1, ksize=3)
    return img_sm, gx, gy


def compute_row_response(gy: np.ndarray, smooth_sigma: float = 3.0) -> np.ndarray:
    resp = np.sum(np.abs(gy), axis=1)
    return gaussian_filter1d(resp, sigma=smooth_sigma)


def find_horizontal_peaks(
    row_resp: np.ndarray,
    h: int,
    min_peak_distance_ratio: float = 0.08,
    min_peak_prominence_ratio: float = 0.15,
):
    distance = max(10, int(h * min_peak_distance_ratio))
    prominence = float(row_resp.max()) * min_peak_prominence_ratio
    peaks, props = find_peaks(row_resp, distance=distance, prominence=prominence)
    return peaks, props


def build_blocks_from_peaks(peaks: np.ndarray, h: int, min_block_h_ratio: float = 0.08):
    peaks = np.sort(np.asarray(peaks, dtype=np.int32))
    min_block_h = max(10, int(h * min_block_h_ratio))
    blocks: list[tuple[int, int]] = []

    for i in range(len(peaks) - 1):
        y0, y1 = int(peaks[i]), int(peaks[i + 1])
        if (y1 - y0) >= min_block_h:
            blocks.append((y0, y1))

    return blocks


def extract_row_candidates_fast_bipolar(
    img_sm: np.ndarray,
    gx: np.ndarray,
    y: int,
    x_min: int,
    x_max: int,
    contrast_win: int = 6,
    row_margin: int = 6,
    topk_each_polarity: int = 2,
    grad_w: float = 1.0,
    contrast_w: float = 0.8,
    min_local_peak_distance: int = 5,
):
    h, w = img_sm.shape
    x0 = max(x_min, row_margin + contrast_win)
    x1 = min(x_max, w - row_margin - contrast_win)
    if x1 <= x0 + 8:
        return []

    row_img = img_sm[y]
    row_gx = np.abs(gx[y]).astype(np.float32)

    xs = np.arange(x0, x1, dtype=np.int32)
    grad_vals = row_gx[x0:x1]

    csum = np.concatenate([[0.0], np.cumsum(row_img, dtype=np.float64)])
    left_sums = csum[xs] - csum[xs - contrast_win]
    right_sums = csum[xs + contrast_win] - csum[xs]
    left_mean = left_sums / contrast_win
    right_mean = right_sums / contrast_win

    diff = left_mean - right_mean
    score_lr = grad_w * grad_vals + contrast_w * np.maximum(diff, 0.0)
    score_rl = grad_w * grad_vals + contrast_w * np.maximum(-diff, 0.0)

    out: list[dict[str, Any]] = []

    peak_idx_lr, _ = find_peaks(score_lr, distance=max(1, min_local_peak_distance))
    if len(peak_idx_lr) > 0:
        order = np.argsort(score_lr[peak_idx_lr])[::-1][:topk_each_polarity]
        for oi in order:
            pi = int(peak_idx_lr[oi])
            out.append(
                {
                    "x": int(xs[pi]),
                    "y": int(y),
                    "score": float(score_lr[pi]),
                    "contrast_lr": float(diff[pi]),
                    "polarity": +1,
                }
            )

    peak_idx_rl, _ = find_peaks(score_rl, distance=max(1, min_local_peak_distance))
    if len(peak_idx_rl) > 0:
        order = np.argsort(score_rl[peak_idx_rl])[::-1][:topk_each_polarity]
        for oi in order:
            pi = int(peak_idx_rl[oi])
            out.append(
                {
                    "x": int(xs[pi]),
                    "y": int(y),
                    "score": float(score_rl[pi]),
                    "contrast_lr": float(diff[pi]),
                    "polarity": -1,
                }
            )

    return out


def collect_block_candidates_fast_bipolar(
    img_sm: np.ndarray,
    gx: np.ndarray,
    block: tuple[int, int],
    search_x_min_ratio: float = 0.02,
    search_x_max_ratio: float = 0.98,
    block_y_margin_ratio: float = 0.04,
    topk_each_polarity: int = 2,
    contrast_win: int = 6,
    row_margin: int = 6,
    grad_w: float = 1.0,
    contrast_w: float = 0.8,
    min_local_peak_distance: int = 5,
    row_step: int = 2,
):
    h, w = img_sm.shape
    y0, y1 = block
    dy = int((y1 - y0) * block_y_margin_ratio)
    yy0 = max(0, y0 + dy)
    yy1 = min(h, y1 - dy)

    x_min = int(w * search_x_min_ratio)
    x_max = int(w * search_x_max_ratio)

    candidates: list[dict[str, Any]] = []
    for y in range(yy0, yy1, row_step):
        candidates.extend(
            extract_row_candidates_fast_bipolar(
                img_sm=img_sm,
                gx=gx,
                y=y,
                x_min=x_min,
                x_max=x_max,
                contrast_win=contrast_win,
                row_margin=row_margin,
                topk_each_polarity=topk_each_polarity,
                grad_w=grad_w,
                contrast_w=contrast_w,
                min_local_peak_distance=min_local_peak_distance,
            )
        )
    return candidates


def fit_single_line_ransac(
    candidates: list[dict[str, Any]],
    residual_threshold: float = 3.0,
    max_trials: int = 200,
    min_points_for_fit: int = 30,
):
    if len(candidates) < min_points_for_fit:
        return None

    ys = np.array([c["y"] for c in candidates], dtype=np.float32).reshape(-1, 1)
    xs = np.array([c["x"] for c in candidates], dtype=np.float32)

    model = RANSACRegressor(
        estimator=LinearRegression(),
        residual_threshold=residual_threshold,
        max_trials=max_trials,
        random_state=0,
    )
    model.fit(ys, xs)

    inlier_mask = model.inlier_mask_
    if inlier_mask is None:
        return None

    n_inliers = int(np.sum(inlier_mask))
    if n_inliers < min_points_for_fit:
        return None

    slope = float(model.estimator_.coef_[0])
    intercept = float(model.estimator_.intercept_)
    pred = model.predict(ys)
    rmse = float(np.sqrt(np.mean((xs[inlier_mask] - pred[inlier_mask]) ** 2)))

    return {
        "model": model,
        "slope": slope,
        "intercept": intercept,
        "n_candidates": len(candidates),
        "n_inliers": n_inliers,
        "rmse": rmse,
        "inlier_mask": inlier_mask.copy(),
    }


def fit_multiple_lines_ransac(
    candidates: list[dict[str, Any]],
    n_lines: int = 1,
    residual_threshold: float = 3.0,
    max_trials: int = 200,
    min_points_for_fit: int = 30,
    min_inliers: int = 20,
):
    remaining = list(candidates)
    lines: list[dict[str, Any]] = []

    for _ in range(n_lines):
        if len(remaining) < min_points_for_fit:
            break

        res = fit_single_line_ransac(
            remaining,
            residual_threshold=residual_threshold,
            max_trials=max_trials,
            min_points_for_fit=min_points_for_fit,
        )
        if res is None or res["n_inliers"] < min_inliers:
            break

        lines.append(res)
        keep_mask = ~res["inlier_mask"]
        remaining = [c for c, keep in zip(remaining, keep_mask) if keep]

    return lines


def line_mean_x_in_block(line: dict[str, Any], block: tuple[int, int]) -> float:
    y0, y1 = block
    yc = 0.5 * (y0 + y1)
    return float(line["slope"] * yc + line["intercept"])


def rank_lines_for_shear(
    lines: list[dict[str, Any]],
    block: tuple[int, int],
    img_width: int,
    rmse_w: float = 2.0,
    side_w: float = 20.0,
):
    ranked: list[dict[str, Any]] = []

    for line in lines:
        mean_x = line_mean_x_in_block(line, block)
        dist_to_nearest_side = min(mean_x, img_width - mean_x)
        side_score = 1.0 - dist_to_nearest_side / (img_width / 2.0)
        rank_score = 1.0 * line["n_inliers"] - rmse_w * line["rmse"] + side_w * side_score

        item = dict(line)
        item["mean_x"] = float(mean_x)
        item["rank_score"] = float(rank_score)
        item["side_score"] = float(side_score)
        ranked.append(item)

    ranked.sort(key=lambda d: d["rank_score"], reverse=True)
    return ranked


def estimate_shear_for_image(img_path: str | Path, params: dict[str, Any] | None = None):
    params = DEFAULT_SHEAR_PARAMS if params is None else params

    img = read_gray01(img_path)
    h, w = img.shape

    img_sm, gx, gy = compute_smoothed_and_gradients(img, blur_sigma=params["blur_sigma"])
    row_resp = compute_row_response(gy, smooth_sigma=params["row_resp_smooth_sigma"])

    peaks, peak_props = find_horizontal_peaks(
        row_resp=row_resp,
        h=h,
        min_peak_distance_ratio=params["min_peak_distance_ratio"],
        min_peak_prominence_ratio=params["min_peak_prominence_ratio"],
    )
    blocks = build_blocks_from_peaks(peaks=peaks, h=h, min_block_h_ratio=params["min_block_h_ratio"])

    block_results: list[dict[str, Any]] = []

    for bi, block in enumerate(blocks):
        candidates = collect_block_candidates_fast_bipolar(
            img_sm=img_sm,
            gx=gx,
            block=block,
            search_x_min_ratio=params["search_x_min_ratio"],
            search_x_max_ratio=params["search_x_max_ratio"],
            block_y_margin_ratio=params["block_y_margin_ratio"],
            topk_each_polarity=params["topk_each_polarity"],
            contrast_win=params["contrast_win"],
            row_margin=params["row_margin"],
            grad_w=params["row_score_grad_w"],
            contrast_w=params["row_score_contrast_w"],
            min_local_peak_distance=params["min_local_peak_distance"],
            row_step=params["row_step"],
        )

        raw_lines = fit_multiple_lines_ransac(
            candidates=candidates,
            n_lines=params["max_lines_per_block"],
            residual_threshold=params["ransac_residual_threshold"],
            max_trials=params["ransac_max_trials"],
            min_points_for_fit=params["min_points_for_fit"],
            min_inliers=params["min_inliers"],
        )

        ranked_lines = rank_lines_for_shear(
            raw_lines,
            block=block,
            img_width=w,
            rmse_w=params["line_rank_rmse_w"],
            side_w=params["line_rank_side_w"],
        )

        best_line = ranked_lines[0] if ranked_lines else None

        block_results.append(
            {
                "block_id": bi,
                "block": block,
                "n_candidates": len(candidates),
                "lines": ranked_lines,
                "best_line": best_line,
            }
        )

    valid_slopes = [br["best_line"]["slope"] for br in block_results if br["best_line"] is not None]

    return {
        "img_path": str(img_path),
        "img": img,
        "img_sm": img_sm,
        "gx": gx,
        "gy": gy,
        "row_resp": row_resp,
        "peaks": peaks,
        "peak_props": peak_props,
        "blocks": blocks,
        "block_results": block_results,
        "global_slope_mean": float(np.mean(valid_slopes)) if valid_slopes else np.nan,
        "global_slope_median": float(np.median(valid_slopes)) if valid_slopes else np.nan,
        "global_slope_std": float(np.std(valid_slopes)) if valid_slopes else np.nan,
    }


def batch_estimate_shear(img_paths: list[str | Path], params: dict[str, Any] | None = None):
    params = DEFAULT_SHEAR_PARAMS if params is None else params
    rows: list[dict[str, Any]] = []
    all_results: dict[str, Any] = {}

    for img_path in tqdm(img_paths, desc="Estimating shear"):
        slide_id = Path(img_path).parent.name
        try:
            res = estimate_shear_for_image(img_path, params)
            all_results[str(img_path)] = res

            for br in res["block_results"]:
                best = br["best_line"]
                row = {
                    "slide_id": slide_id,
                    "img_path": str(img_path),
                    "block_id": br["block_id"],
                    "block_y0": br["block"][0],
                    "block_y1": br["block"][1],
                    "n_candidates": br["n_candidates"],
                    "global_slope_mean": res["global_slope_mean"],
                    "global_slope_median": res["global_slope_median"],
                    "global_slope_std": res["global_slope_std"],
                    "error": "",
                }

                if best is not None:
                    row.update(
                        {
                            "slope": best["slope"],
                            "intercept": best["intercept"],
                            "mean_x": best["mean_x"],
                            "rank_score": best["rank_score"],
                            "side_score": best["side_score"],
                            "n_inliers": best["n_inliers"],
                            "rmse": best["rmse"],
                        }
                    )
                else:
                    row.update(
                        {
                            "slope": np.nan,
                            "intercept": np.nan,
                            "mean_x": np.nan,
                            "rank_score": np.nan,
                            "side_score": np.nan,
                            "n_inliers": 0,
                            "rmse": np.nan,
                        }
                    )

                rows.append(row)
        except Exception as e:
            rows.append(
                {
                    "slide_id": slide_id,
                    "img_path": str(img_path),
                    "block_id": -1,
                    "block_y0": np.nan,
                    "block_y1": np.nan,
                    "n_candidates": 0,
                    "slope": np.nan,
                    "intercept": np.nan,
                    "mean_x": np.nan,
                    "rank_score": np.nan,
                    "side_score": np.nan,
                    "n_inliers": 0,
                    "rmse": np.nan,
                    "global_slope_mean": np.nan,
                    "global_slope_median": np.nan,
                    "global_slope_std": np.nan,
                    "error": str(e),
                }
            )

    return pd.DataFrame(rows), all_results
