from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np
import pandas as pd
from scipy.ndimage import gaussian_filter1d
from scipy.signal import find_peaks
from tqdm.auto import tqdm

from geom.geom_shear import (
    build_blocks_from_peaks,
    compute_row_response,
    compute_smoothed_and_gradients,
    find_horizontal_peaks,
    read_gray01,
)


DEFAULT_ANCHOR_PARAMS: dict[str, Any] = {
    "top_search_band_ratio": 0.12,
    "top_edge_smooth_sigma": 2.0,
    "top_edge_prominence_ratio": 0.20,
    "intercept_search_x_min_ratio": 0.00,
    "intercept_search_x_max_ratio": 1.00,
    "intercept_y_margin_ratio": 0.05,
    "intercept_score_grad_w": 1.0,
    "intercept_score_contrast_w": 0.8,
    "intercept_contrast_win": 6,
    "intercept_coarse_step": 8,
    "intercept_refine_radius": 8,
    "intercept_refine_step": 1,
    "intercept_sample_step_y": 4,
    "anchor_track_local_radius": 24,
    "anchor_track_fallback_global": True,
    "crop_offset_x": 16,
    "crop_offset_y": 16,
}


def line_x_from_b(y: float, s: float, b: float) -> float:
    return s * y + b


def nearest_side_from_x(x: float, w: int) -> str:
    return "left" if x < (w / 2) else "right"


def build_row_cumsum(img_sm: np.ndarray) -> np.ndarray:
    h, w = img_sm.shape
    row_cumsum = np.zeros((h, w + 1), dtype=np.float32)
    row_cumsum[:, 1:] = np.cumsum(img_sm, axis=1, dtype=np.float32)
    return row_cumsum


def find_top_boundary_in_block(img_sm: np.ndarray, gy: np.ndarray, block: tuple[int, int], params: dict[str, Any]):
    h, w = img_sm.shape
    y0, y1 = block

    band_h = max(10, int((y1 - y0) * params["top_search_band_ratio"]))
    yy0, yy1 = y0, min(h, y0 + band_h)
    if yy1 <= yy0 + 5:
        return None

    row_resp_local = np.sum(np.abs(gy[yy0:yy1, :]), axis=1)
    row_resp_local = gaussian_filter1d(row_resp_local, sigma=params["top_edge_smooth_sigma"])

    prominence = float(row_resp_local.max()) * params["top_edge_prominence_ratio"]
    peaks, _ = find_peaks(row_resp_local, prominence=prominence)

    peak_local = int(np.argmax(row_resp_local)) if len(peaks) == 0 else int(peaks[np.argmax(row_resp_local[peaks])])
    y_top = yy0 + peak_local

    return {
        "y_top": int(y_top),
        "row_resp_local": row_resp_local,
        "search_band": (yy0, yy1),
    }


def score_intercept_b_fast(
    img_sm: np.ndarray,
    gx: np.ndarray,
    row_cumsum: np.ndarray,
    block: tuple[int, int],
    s0: float,
    b: float,
    contrast_win: int = 6,
    grad_w: float = 1.0,
    contrast_w: float = 0.8,
    y_margin_ratio: float = 0.05,
    sample_step_y: int = 4,
):
    h, w = img_sm.shape
    y0, y1 = block

    dy = int((y1 - y0) * y_margin_ratio)
    yy0, yy1 = max(0, y0 + dy), min(h, y1 - dy)
    if yy1 <= yy0 + 10:
        return None

    ys = np.arange(yy0, yy1, sample_step_y, dtype=np.int32)
    xs = s0 * ys + b
    xs_i = np.round(xs).astype(np.int32)

    valid = (xs_i >= contrast_win) & (xs_i < w - contrast_win)
    ys, xs_i = ys[valid], xs_i[valid]
    if len(ys) < 20:
        return None

    grad_vals = np.abs(gx[ys, xs_i]).astype(np.float32)

    l0, l1 = xs_i - contrast_win, xs_i
    r0, r1 = xs_i, xs_i + contrast_win

    left_sums = row_cumsum[ys, l1] - row_cumsum[ys, l0]
    right_sums = row_cumsum[ys, r1] - row_cumsum[ys, r0]

    left_means = left_sums / float(contrast_win)
    right_means = right_sums / float(contrast_win)

    diff = left_means - right_means
    contrast_term = np.abs(diff)
    score_per_point = grad_w * grad_vals + contrast_w * contrast_term

    mean_x = float(xs_i.mean())
    side = nearest_side_from_x(mean_x, w)
    polarity = +1 if float(np.mean(diff)) >= 0 else -1

    return {
        "b": float(b),
        "score": float(score_per_point.mean()),
        "mean_x": mean_x,
        "side": side,
        "polarity": polarity,
        "n_points": int(len(ys)),
        "ys": ys,
        "xs": xs_i,
    }


def compute_global_b_range(img_shape: tuple[int, int], block: tuple[int, int], s0: float, params: dict[str, Any]):
    h, w = img_shape
    x_min = int(w * params["intercept_search_x_min_ratio"])
    x_max = int(w * params["intercept_search_x_max_ratio"])
    y0, y1 = block
    yc = 0.5 * (y0 + y1)
    return (x_min - s0 * yc, x_max - s0 * yc)


def search_intercept_in_range(
    img_sm: np.ndarray,
    gx: np.ndarray,
    row_cumsum: np.ndarray,
    block: tuple[int, int],
    s0: float,
    params: dict[str, Any],
    b_search_range: tuple[float, float],
):
    b_min_search, b_max_search = b_search_range
    if b_max_search < b_min_search:
        return None

    coarse_step = params["intercept_coarse_step"]
    refine_radius = params["intercept_refine_radius"]
    refine_step = params["intercept_refine_step"]
    sample_step_y = params["intercept_sample_step_y"]

    coarse_scored: list[dict[str, Any]] = []
    for b in np.arange(int(np.floor(b_min_search)), int(np.ceil(b_max_search)) + 1, coarse_step):
        item = score_intercept_b_fast(
            img_sm=img_sm,
            gx=gx,
            row_cumsum=row_cumsum,
            block=block,
            s0=s0,
            b=b,
            contrast_win=params["intercept_contrast_win"],
            grad_w=params["intercept_score_grad_w"],
            contrast_w=params["intercept_score_contrast_w"],
            y_margin_ratio=params["intercept_y_margin_ratio"],
            sample_step_y=sample_step_y,
        )
        if item is not None:
            coarse_scored.append(item)

    if not coarse_scored:
        return None

    coarse_scored.sort(key=lambda d: d["score"], reverse=True)
    best_coarse = coarse_scored[0]
    b0 = int(round(best_coarse["b"]))

    b_left = max(int(np.floor(b_min_search)), b0 - refine_radius)
    b_right = min(int(np.ceil(b_max_search)), b0 + refine_radius)

    fine_scored: list[dict[str, Any]] = []
    for b in np.arange(b_left, b_right + 1, refine_step):
        item = score_intercept_b_fast(
            img_sm=img_sm,
            gx=gx,
            row_cumsum=row_cumsum,
            block=block,
            s0=s0,
            b=b,
            contrast_win=params["intercept_contrast_win"],
            grad_w=params["intercept_score_grad_w"],
            contrast_w=params["intercept_score_contrast_w"],
            y_margin_ratio=params["intercept_y_margin_ratio"],
            sample_step_y=sample_step_y,
        )
        if item is not None:
            fine_scored.append(item)

    if not fine_scored:
        return {
            "best": best_coarse,
            "coarse_best": best_coarse,
            "coarse_scored": coarse_scored,
            "fine_scored": [],
        }

    fine_scored.sort(key=lambda d: d["score"], reverse=True)
    return {
        "best": fine_scored[0],
        "coarse_best": best_coarse,
        "coarse_scored": coarse_scored,
        "fine_scored": fine_scored,
    }


def search_intercept_in_block(
    img_sm: np.ndarray,
    gx: np.ndarray,
    row_cumsum: np.ndarray,
    block: tuple[int, int],
    s0: float,
    params: dict[str, Any],
    prev_b: float | None = None,
):
    global_range = compute_global_b_range(img_sm.shape, block, s0, params)
    local_radius = params["anchor_track_local_radius"]
    fallback_global = params["anchor_track_fallback_global"]

    if prev_b is None:
        res = search_intercept_in_range(img_sm, gx, row_cumsum, block, s0, params, global_range)
        if res is None:
            return None
        res["search_mode"] = "global"
        return res

    local_range = (prev_b - local_radius, prev_b + local_radius)
    res_local = search_intercept_in_range(img_sm, gx, row_cumsum, block, s0, params, local_range)
    if res_local is not None:
        res_local["search_mode"] = "local"
        res_local["prev_b"] = float(prev_b)
        return res_local

    if fallback_global:
        res_global = search_intercept_in_range(img_sm, gx, row_cumsum, block, s0, params, global_range)
        if res_global is not None:
            res_global["search_mode"] = "fallback_global"
            res_global["prev_b"] = float(prev_b)
            return res_global

    return None


def build_safe_crop_point(A_ref: tuple[float, float], polarity: int, params: dict[str, Any]):
    x_ref, y_ref = A_ref
    dx, dy = params["crop_offset_x"], params["crop_offset_y"]

    x_crop = x_ref - dx if polarity == +1 else x_ref + dx
    y_crop = y_ref - dy

    return (float(x_crop), float(y_crop))


def detect_anchor_for_block(
    img_sm: np.ndarray,
    gx: np.ndarray,
    gy: np.ndarray,
    row_cumsum: np.ndarray,
    block: tuple[int, int],
    s0: float,
    params: dict[str, Any],
    prev_b: float | None = None,
):
    top_res = find_top_boundary_in_block(img_sm, gy, block, params)
    if top_res is None:
        return None

    y_top = top_res["y_top"]
    intercept_res = search_intercept_in_block(img_sm, gx, row_cumsum, block, s0, params, prev_b=prev_b)
    if intercept_res is None:
        return None

    best = intercept_res["best"]
    b = best["b"]
    polarity = int(best["polarity"])

    x_ref = line_x_from_b(y_top, s0, b)
    A_ref = (float(x_ref), float(y_top))
    A_crop = build_safe_crop_point(A_ref, polarity=polarity, params=params)

    return {
        "block": block,
        "y_top": int(y_top),
        "b": float(b),
        "side": best["side"],
        "polarity": polarity,
        "score": float(best["score"]),
        "mean_x": float(best["mean_x"]),
        "A_ref": A_ref,
        "A_crop": A_crop,
        "top_res": top_res,
        "intercept_res": intercept_res,
    }


def detect_anchors_for_image(
    img_path: str | Path,
    s0: float,
    params: dict[str, Any] | None = None,
    blur_sigma: float = 1.0,
):
    params = DEFAULT_ANCHOR_PARAMS if params is None else params

    img = read_gray01(img_path)
    h, w = img.shape

    img_sm, gx, gy = compute_smoothed_and_gradients(img, blur_sigma=blur_sigma)
    row_cumsum = build_row_cumsum(img_sm)

    row_resp = compute_row_response(gy, smooth_sigma=3.0)
    peaks, peak_props = find_horizontal_peaks(row_resp, h=h)
    blocks = build_blocks_from_peaks(peaks, h=h)

    block_results: list[dict[str, Any]] = []
    prev_b: float | None = None

    for bi, block in enumerate(blocks):
        anchor_res = detect_anchor_for_block(
            img_sm=img_sm,
            gx=gx,
            gy=gy,
            row_cumsum=row_cumsum,
            block=block,
            s0=s0,
            params=params,
            prev_b=prev_b,
        )
        if anchor_res is not None:
            prev_b = anchor_res["b"]

        block_results.append(
            {
                "block_id": bi,
                "block": block,
                "anchor_res": anchor_res,
            }
        )

    return {
        "img_path": str(img_path),
        "img": img,
        "img_sm": img_sm,
        "gx": gx,
        "gy": gy,
        "row_resp": row_resp,
        "peaks": peaks,
        "blocks": blocks,
        "block_results": block_results,
        "s0": s0,
    }


def batch_detect_anchors(
    img_paths: list[str | Path],
    s0: float,
    params: dict[str, Any] | None = None,
    blur_sigma: float = 1.0,
):
    params = DEFAULT_ANCHOR_PARAMS if params is None else params
    rows: list[dict[str, Any]] = []
    all_results: dict[str, Any] = {}

    for img_path in tqdm(img_paths, desc="Detecting anchors"):
        slide_id = Path(img_path).parent.name
        try:
            res = detect_anchors_for_image(img_path, s0=s0, params=params, blur_sigma=blur_sigma)
            all_results[str(img_path)] = res

            for br in res["block_results"]:
                ar = br["anchor_res"]
                row = {
                    "slide_id": slide_id,
                    "img_path": str(img_path),
                    "block_id": br["block_id"],
                    "block_y0": br["block"][0],
                    "block_y1": br["block"][1],
                    "s0": s0,
                    "error": "",
                }

                if ar is None:
                    row.update(
                        {
                            "y_top": np.nan,
                            "b": np.nan,
                            "side": "",
                            "polarity": np.nan,
                            "score": np.nan,
                            "x_ref": np.nan,
                            "y_ref": np.nan,
                            "x_crop": np.nan,
                            "y_crop": np.nan,
                            "search_mode": "",
                        }
                    )
                else:
                    row.update(
                        {
                            "y_top": ar["y_top"],
                            "b": ar["b"],
                            "side": ar["side"],
                            "polarity": ar["polarity"],
                            "score": ar["score"],
                            "x_ref": ar["A_ref"][0],
                            "y_ref": ar["A_ref"][1],
                            "x_crop": ar["A_crop"][0],
                            "y_crop": ar["A_crop"][1],
                            "search_mode": ar["intercept_res"].get("search_mode", ""),
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
                    "s0": s0,
                    "y_top": np.nan,
                    "b": np.nan,
                    "side": "",
                    "polarity": np.nan,
                    "score": np.nan,
                    "x_ref": np.nan,
                    "y_ref": np.nan,
                    "x_crop": np.nan,
                    "y_crop": np.nan,
                    "search_mode": "",
                    "error": str(e),
                }
            )

    return pd.DataFrame(rows), all_results