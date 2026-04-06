from __future__ import annotations

from pathlib import Path
from typing import Any

import cv2
import numpy as np

from geom.geom_anchor import detect_anchors_for_image


DEFAULT_GEOM_PARAMS: dict[str, Any] = {
    "frame_width": 2200,
    "frame_height": 1125,
    "save_before_shear": False
}


def read_any_png(path: str | Path) -> np.ndarray:
    """
    Read a PNG image and normalize to [0, 1].

    Returns:
        - HxW float32 for grayscale
        - HxWx3 float32 RGB for color images
    """
    img = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(path)

    if img.ndim == 2:
        return img.astype(np.float32) / 255.0

    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    return img.astype(np.float32) / 255.0


def save_png01(path: str | Path, img01: np.ndarray) -> None:
    """
    Save a [0, 1] float image to PNG.
    Supports grayscale and RGB.
    """
    arr = np.clip(img01, 0.0, 1.0)

    if arr.ndim == 2:
        out = (arr * 255.0).round().astype(np.uint8)
        cv2.imwrite(str(path), out)
        return

    if arr.ndim == 3 and arr.shape[2] == 3:
        out = (arr * 255.0).round().astype(np.uint8)
        out_bgr = cv2.cvtColor(out, cv2.COLOR_RGB2BGR)
        cv2.imwrite(str(path), out_bgr)
        return

    raise ValueError(f"Unsupported image shape for save_png01: {arr.shape}")


def anchor_to_linear_index(
    img_shape: tuple[int, int] | tuple[int, int, int],
    anchor_xy: tuple[float, float],
) -> int:
    """
    Convert anchor coordinates (x, y) to a row-major linear index.
    """
    h, w = img_shape[:2]
    x, y = anchor_xy

    x_i = int(round(x))
    y_i = int(round(y))

    x_i = min(max(x_i, 0), w - 1)
    y_i = min(max(y_i, 0), h - 1)

    return y_i * w + x_i


def extract_frame_by_anchor_reindex(
    full_img: np.ndarray,
    anchor_xy: tuple[float, float],
    frame_width: int,
    frame_height: int,
):
    """
    Extract one frame by direct 1D row-major reindexing.

    Logic:
    - Flatten the image in row-major order
    - Start from anchor linear index
    - Read frame_width * frame_height pixels continuously
    - Wrap around if needed
    - Reshape to (frame_height, frame_width)
    """
    h, w = full_img.shape[:2]
    n = frame_width * frame_height
    start = anchor_to_linear_index(full_img.shape, anchor_xy)

    if full_img.ndim == 2:
        flat = full_img.reshape(-1)
        total = flat.size
        idx = (start + np.arange(n, dtype=np.int64)) % total
        frame = flat[idx].reshape(frame_height, frame_width)
    else:
        c = full_img.shape[2]
        flat = full_img.reshape(-1, c)
        total = flat.shape[0]
        idx = (start + np.arange(n, dtype=np.int64)) % total
        frame = flat[idx].reshape(frame_height, frame_width, c)

    return frame, {
        "start_index": int(start),
        "total_pixels": int(h * w),
        "frame_pixels": int(n),
        "anchor_x": float(anchor_xy[0]),
        "anchor_y": float(anchor_xy[1]),
    }


def shear_deskew_frame(img: np.ndarray, s0: float) -> np.ndarray:
    """
    Circular subpixel shear correction along x with wrap-around boundary.

    For each row y:
        shift = s0 * y

    Then apply wrap-around linear interpolation.
    This preserves horizontal cyclic continuity.
    """
    img_f = img.astype(np.float32, copy=False)
    h, w = img_f.shape[:2]
    out = np.empty_like(img_f)

    if img_f.ndim == 2:
        for y in range(h):
            shift = float(s0 * y)
            k = int(np.floor(shift))
            alpha = shift - k

            row0 = np.roll(img_f[y], -k)
            row1 = np.roll(img_f[y], -(k + 1))
            out[y] = (1.0 - alpha) * row0 + alpha * row1

        return out.astype(img.dtype, copy=False)

    for y in range(h):
        shift = float(s0 * y)
        k = int(np.floor(shift))
        alpha = shift - k

        row0 = np.roll(img_f[y], -k, axis=0)
        row1 = np.roll(img_f[y], -(k + 1), axis=0)
        out[y] = (1.0 - alpha) * row0 + alpha * row1

    return out.astype(img.dtype, copy=False)


def correct_one_variant_with_geometry(
    img_path: str | Path,
    a_crop: tuple[float, float],
    s0: float,
    frame_width: int,
    frame_height: int,
):
    """
    Correct one image variant using known geometry:
    1. Direct 1D reindex using A_crop
    2. Circular subpixel shear correction
    """
    full_img = read_any_png(img_path)

    frame_before_shear, reindex_info = extract_frame_by_anchor_reindex(
        full_img=full_img,
        anchor_xy=a_crop,
        frame_width=frame_width,
        frame_height=frame_height,
    )

    frame_after_shear = shear_deskew_frame(
        frame_before_shear,
        s0=s0,
    )

    return {
        "img_path": str(img_path),
        "full_img_shape": tuple(full_img.shape),
        "frame_before_shear": frame_before_shear,
        "frame_after_shear": frame_after_shear,
        "reindex_info": reindex_info,
    }


def detect_geometry_from_amp(
    amp_img_path: str | Path,
    s0: float,
    anchor_params: dict[str, Any],
):
    """
    Detect anchor geometry from the amp grayscale image.
    """
    anchor_full = detect_anchors_for_image(
        img_path=amp_img_path,
        s0=s0,
        params=anchor_params,
        blur_sigma=1.0,
    )
    return anchor_full