from __future__ import annotations

import traceback
from pathlib import Path

import numpy as np
from scipy.signal import firwin, lfilter, resample_poly

from tempest_io import (
    build_output_paths,
    read_bb_or_mat,
    save_json,
    save_npy,
    save_uint8_png,
)


# ============================================================
# Basic signal processing
# ============================================================

def remove_dc(x: np.ndarray, dc_remove_len: int = 10000) -> np.ndarray:
    """
    Remove DC by subtracting the mean estimated from the first dc_remove_len samples.
    """
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(f"remove_dc expects 1D input, got shape={x.shape}")
    if len(x) == 0:
        raise ValueError("remove_dc received empty input")

    n = min(len(x), dc_remove_len)
    dc = np.mean(x[:n])
    return (x - dc).astype(np.complex64, copy=False)


def estimate_freq_offset(x: np.ndarray, Fs: float, m: int = 2000) -> float:
    """
    Estimate frequency offset using lag-m phase difference.
    Return frequency offset in Hz.
    """
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(f"estimate_freq_offset expects 1D input, got shape={x.shape}")
    if len(x) <= m:
        raise ValueError(
            f"Signal too short for frequency offset estimation: len={len(x)}, m={m}"
        )

    r = x[m:] * np.conj(x[:-m])
    s = np.sum(r)
    ang = np.angle(s)
    foff = ang / (2 * np.pi * m / Fs)
    return float(foff)


def apply_freq_offset_correction(x: np.ndarray, Fs: float, foff: float) -> np.ndarray:
    """
    Apply frequency offset correction exp(-j*2*pi*foff*n/Fs).
    """
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(
            f"apply_freq_offset_correction expects 1D input, got shape={x.shape}"
        )

    n = np.arange(len(x), dtype=np.float64)
    y = x * np.exp(-2j * np.pi * foff * n / Fs)
    return y.astype(np.complex64, copy=False)


def lowpass_filter(x: np.ndarray, Fs: float, BW: float, numtaps: int) -> np.ndarray:
    """
    Lowpass FIR filtering.
    """
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(f"lowpass_filter expects 1D input, got shape={x.shape}")
    if BW <= 0 or BW >= Fs / 2:
        raise ValueError(f"Invalid BW={BW}. Must satisfy 0 < BW < Fs/2")
    if numtaps <= 1:
        raise ValueError(f"numtaps must be > 1, got {numtaps}")

    nyq = Fs / 2.0
    b = firwin(numtaps, cutoff=BW / nyq)
    y = np.asarray(lfilter(b, 1.0, x))
    return y.astype(np.complex64, copy=False)


def resample_to_pixel_rate(x: np.ndarray, up: int, down: int) -> np.ndarray:
    """
    Resample to pixel-rate domain using rational resampling.
    """
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(
            f"resample_to_pixel_rate expects 1D input, got shape={x.shape}"
        )
    if up <= 0 or down <= 0:
        raise ValueError(f"up/down must be > 0, got up={up}, down={down}")

    y = resample_poly(x, up, down)
    return y.astype(np.complex64, copy=False)


# ============================================================
# Frame utilities
# ============================================================

def get_frame_sample_count(h_total: int, v_total: int) -> int:
    """Return samples required for one frame."""
    if h_total <= 0 or v_total <= 0:
        raise ValueError("h_total and v_total must be > 0")
    return int(h_total * v_total)


def get_available_frame_count(rx_pix: np.ndarray, h_total: int, v_total: int) -> int:
    """Return number of complete frames available in rx_pix."""
    rx_pix = np.asarray(rx_pix)
    Npix = get_frame_sample_count(h_total, v_total)
    return int(len(rx_pix) // Npix)


def extract_frame(
    rx_pix: np.ndarray,
    h_total: int,
    v_total: int,
    frame_idx: int = 0,
) -> np.ndarray:
    """
    Extract frame_idx-th frame from resampled data.
    Return complex image with shape (v_total, h_total).
    """
    rx_pix = np.asarray(rx_pix)
    if rx_pix.ndim != 1:
        raise ValueError(f"extract_frame expects 1D input, got shape={rx_pix.shape}")
    if frame_idx < 0:
        raise ValueError(f"frame_idx must be >= 0, got {frame_idx}")

    Npix = get_frame_sample_count(h_total, v_total)
    start = frame_idx * Npix
    end = start + Npix

    if end > len(rx_pix):
        raise ValueError(
            f"Not enough samples for frame {frame_idx}: "
            f"need end={end}, got len={len(rx_pix)}"
        )

    return rx_pix[start:end].reshape((v_total, h_total))


# ============================================================
# Visualization
# ============================================================

def normalize_by_percentile(
    x: np.ndarray,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> tuple[np.ndarray, float, float]:
    """
    Normalize x into [0,1] using percentile clipping.
    Returns: (normalized_array, vmin, vmax)
    """
    x = np.asarray(x)
    vmin, vmax = np.percentile(x, (p_low, p_high))
    denom = max(float(vmax - vmin), eps)
    y = np.clip((x - vmin) / denom, 0, 1).astype(np.float32)
    return y, float(vmin), float(vmax)


def make_iq_vis(
    img_complex: np.ndarray,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> np.ndarray:
    """
    Make pseudo-color IQ visualization:
    R = normalized I
    G = normalized Q
    B = 0
    Output range: [0,1]
    """
    I = np.real(img_complex)
    Q = np.imag(img_complex)

    iq_stack = np.hstack((I.ravel(), Q.ravel()))
    vmin, vmax = np.percentile(iq_stack, (p_low, p_high))
    denom = max(float(vmax - vmin), eps)

    Ir = np.clip((I - vmin) / denom, 0, 1).astype(np.float32)
    Qr = np.clip((Q - vmin) / denom, 0, 1).astype(np.float32)
    B = np.zeros_like(Ir, dtype=np.float32)

    return np.stack([Ir, Qr, B], axis=-1)


def make_amp_image(
    img_complex: np.ndarray,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> np.ndarray:
    """
    Raw linear amplitude image in [0,1].
    """
    amp = np.abs(img_complex)
    amp_norm, _, _ = normalize_by_percentile(amp, p_low, p_high, eps)
    return amp_norm


def make_amp_gain_image(
    img_complex: np.ndarray,
    gain_linear: float,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> np.ndarray:
    """
    Linear amplitude image + linear gain.
    """
    amp_norm = make_amp_image(img_complex, p_low, p_high, eps)
    return np.clip(amp_norm * gain_linear, 0, 1).astype(np.float32)


def make_amp_log_gain_image(
    img_complex: np.ndarray,
    gain_log: float,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> np.ndarray:
    """
    Log-compressed amplitude image + gain.
    """
    amp = np.abs(img_complex)
    amp_db = 20 * np.log10(amp + eps)
    amp_db_norm, _, _ = normalize_by_percentile(amp_db, p_low, p_high, eps)
    return np.clip(amp_db_norm * gain_log, 0, 1).astype(np.float32)


# ============================================================
# Single-file pipeline
# ============================================================

def process_one_file(
    file_in: str,
    cfg: dict,
    output_dir: str,
) -> dict:
    """
    Process one input file and save outputs.

    Returns a result dictionary:
    {
        "file": "...",
        "stem": "...",
        "success": True/False,
        "error": None or "...",
        "loaded_samples": ...,
        "resampled_samples": ...,
        "available_frames": ...,
        "frame_idx": ...,
        "freq_offset_hz": ...,
        "saved_files": [...],
    }
    """
    result = {
    "file": str(file_in),
    "stem": Path(file_in).stem,
    "success": False,
    "error": None,
    "traceback": None,
    "loaded_samples": None,
    "resampled_samples": None,
    "available_frames": None,
    "frame_idx": cfg["processing"]["frame_idx"],
    "freq_offset_hz": None,
    "saved_files": [],

    # ---- experiment parameters ----
    "Fs": cfg["signal"]["Fs"],
    "pixel_rate": cfg["signal"]["pixel_rate"],
    "h_total": cfg["signal"]["h_total"],
    "v_total": cfg["signal"]["v_total"],
    "up": cfg["signal"]["up"],
    "down": cfg["signal"]["down"],
    "BW": cfg["processing"]["BW"],
    "numtaps": cfg["processing"]["numtaps"],
    "dc_remove_len": cfg["processing"]["dc_remove_len"],
    "freq_est_m": cfg["processing"]["freq_est_m"],
    "gain_linear": cfg["visualization"]["gain_linear"],
    "gain_log": cfg["visualization"]["gain_log"],
    "percentile_low": cfg["visualization"]["percentile_low"],
    "percentile_high": cfg["visualization"]["percentile_high"],
    }

    try:
        signal_cfg = cfg["signal"]
        proc_cfg = cfg["processing"]
        out_cfg = cfg["output"]
        vis_cfg = cfg["visualization"]

        # ---------- IO ----------
        paths = build_output_paths(file_in, output_dir)

        # ---------- Read ----------
        rx = read_bb_or_mat(file_in)
        result["loaded_samples"] = int(len(rx))

        # ---------- DC removal ----------
        rx = remove_dc(rx, proc_cfg["dc_remove_len"])

        # ---------- Frequency offset estimation + correction ----------
        foff = estimate_freq_offset(rx, signal_cfg["Fs"], proc_cfg["freq_est_m"])
        result["freq_offset_hz"] = float(foff)

        rx = apply_freq_offset_correction(rx, signal_cfg["Fs"], foff)

        # ---------- Filtering ----------
        rx_filt = lowpass_filter(
            rx,
            signal_cfg["Fs"],
            proc_cfg["BW"],
            proc_cfg["numtaps"],
        )

        # ---------- Resampling ----------
        rx_pix = resample_to_pixel_rate(
            rx_filt,
            signal_cfg["up"],
            signal_cfg["down"],
        )
        result["resampled_samples"] = int(len(rx_pix))

        # ---------- Frame count ----------
        available_frames = get_available_frame_count(
            rx_pix,
            signal_cfg["h_total"],
            signal_cfg["v_total"],
        )
        result["available_frames"] = int(available_frames)

        # ---------- Extract requested frame ----------
        img_complex = extract_frame(
            rx_pix,
            signal_cfg["h_total"],
            signal_cfg["v_total"],
            proc_cfg["frame_idx"],
        )

        # ---------- Save NPY ----------
        if out_cfg["save_complex_npy"]:
            save_npy(paths["npy"], img_complex)
            result["saved_files"].append(str(paths["npy"]))

        # ---------- Visualization ----------
        p_low = vis_cfg["percentile_low"]
        p_high = vis_cfg["percentile_high"]
        eps = vis_cfg["eps"]

        if out_cfg["save_iq_png"]:
            iq_vis = make_iq_vis(img_complex, p_low, p_high, eps)
            save_uint8_png(paths["iq_png"], iq_vis)
            result["saved_files"].append(str(paths["iq_png"]))

        if out_cfg["save_amp_png"]:
            amp_img = make_amp_image(img_complex, p_low, p_high, eps)
            save_uint8_png(paths["amp_png"], amp_img)
            result["saved_files"].append(str(paths["amp_png"]))

        if out_cfg["save_amp_gain_png"]:
            amp_gain_img = make_amp_gain_image(
                img_complex,
                vis_cfg["gain_linear"],
                p_low,
                p_high,
                eps,
            )
            save_uint8_png(paths["amp_gain_png"], amp_gain_img)
            result["saved_files"].append(str(paths["amp_gain_png"]))

        if out_cfg["save_amp_log_gain_png"]:
            amp_log_gain_img = make_amp_log_gain_image(
                img_complex,
                vis_cfg["gain_log"],
                p_low,
                p_high,
                eps,
            )
            save_uint8_png(paths["amp_log_gain_png"], amp_log_gain_img)
            result["saved_files"].append(str(paths["amp_log_gain_png"]))

        # ---------- Meta ----------
        if out_cfg["save_meta_json"]:
            meta = {
                "input_file": str(file_in),
                "loaded_samples": result["loaded_samples"],
                "resampled_samples": result["resampled_samples"],
                "available_frames": result["available_frames"],
                "frame_idx": result["frame_idx"],
                "freq_offset_hz": result["freq_offset_hz"],
                "saved_files": result["saved_files"],
                "config": cfg,
            }
            save_json(paths["meta_json"], meta)
            result["saved_files"].append(str(paths["meta_json"]))

        result["success"] = True
        return result

    except Exception as e:
        result["error"] = str(e)
        result["traceback"] = traceback.format_exc()
        return result