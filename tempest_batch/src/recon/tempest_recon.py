from __future__ import annotations

import traceback
from pathlib import Path
from typing import Any

import numpy as np
from scipy.signal import firwin, lfilter, resample_poly

from recon.tempest_io import (
    build_output_paths,
    flatten_meta,
    read_bb_or_mat,
    save_json,
    save_npy,
    save_uint8_png,
)


def remove_dc(x: np.ndarray, dc_remove_len: int = 10000) -> np.ndarray:
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(f"remove_dc expects 1D input, got shape={x.shape}")
    if len(x) == 0:
        raise ValueError("remove_dc received empty input")

    n = min(len(x), dc_remove_len)
    dc = np.mean(x[:n])
    return (x - dc).astype(np.complex64, copy=False)


def estimate_freq_offset(x: np.ndarray, Fs: float, m: int = 2000) -> float:
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
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(
            f"apply_freq_offset_correction expects 1D input, got shape={x.shape}"
        )

    n = np.arange(len(x), dtype=np.float64)
    y = x * np.exp(-2j * np.pi * foff * n / Fs)
    return y.astype(np.complex64, copy=False)


def lowpass_filter(x: np.ndarray, Fs: float, BW: float, numtaps: int) -> np.ndarray:
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
    x = np.asarray(x)
    if x.ndim != 1:
        raise ValueError(
            f"resample_to_pixel_rate expects 1D input, got shape={x.shape}"
        )
    if up <= 0 or down <= 0:
        raise ValueError(f"up/down must be > 0, got up={up}, down={down}")

    y = resample_poly(x, up, down)
    return y.astype(np.complex64, copy=False)


def get_frame_sample_count(h_total: int, v_total: int) -> int:
    if h_total <= 0 or v_total <= 0:
        raise ValueError("h_total and v_total must be > 0")
    return int(h_total * v_total)


def get_available_frame_count(
    rx_pix: np.ndarray,
    h_total: int,
    v_total: int,
    start_offset_samples: int = 0,
) -> int:
    rx_pix = np.asarray(rx_pix)
    Npix = get_frame_sample_count(h_total, v_total)

    if start_offset_samples < 0:
        raise ValueError("start_offset_samples must be >= 0")
    if start_offset_samples >= len(rx_pix):
        return 0

    usable = len(rx_pix) - start_offset_samples
    return int(usable // Npix)


def extract_frame(
    rx_pix: np.ndarray,
    h_total: int,
    v_total: int,
    frame_idx: int = 0,
    start_offset_samples: int = 0,
) -> np.ndarray:
    rx_pix = np.asarray(rx_pix)
    if rx_pix.ndim != 1:
        raise ValueError(f"extract_frame expects 1D input, got shape={rx_pix.shape}")
    if frame_idx < 0:
        raise ValueError(f"frame_idx must be >= 0, got {frame_idx}")
    if start_offset_samples < 0:
        raise ValueError("start_offset_samples must be >= 0")

    Npix = get_frame_sample_count(h_total, v_total)
    start = start_offset_samples + frame_idx * Npix
    end = start + Npix

    if end > len(rx_pix):
        raise ValueError(
            f"Not enough samples for frame {frame_idx}: "
            f"need end={end}, got len={len(rx_pix)}"
        )

    return rx_pix[start:end].reshape((v_total, h_total))


def make_frame_indices(frame_start: int, frame_count: int) -> list[int]:
    if frame_start < 0:
        raise ValueError("frame_start must be >= 0")
    if frame_count <= 0:
        raise ValueError("frame_count must be > 0")
    return list(range(frame_start, frame_start + frame_count))


def extract_frames(
    rx_pix: np.ndarray,
    h_total: int,
    v_total: int,
    frame_indices: list[int],
    start_offset_samples: int = 0,
) -> list[np.ndarray]:
    frames = []
    for idx in frame_indices:
        frames.append(
            extract_frame(
                rx_pix,
                h_total,
                v_total,
                idx,
                start_offset_samples=start_offset_samples,
            )
        )
    return frames


def make_stacked_complex_image(
    rx_pix: np.ndarray,
    h_total: int,
    v_total: int,
    frame_start: int,
    frame_count: int,
    direction: str = "vertical",
    start_offset_samples: int = 0,
) -> np.ndarray:
    frame_indices = make_frame_indices(frame_start, frame_count)
    frames = extract_frames(
        rx_pix,
        h_total,
        v_total,
        frame_indices,
        start_offset_samples=start_offset_samples,
    )

    if len(frames) == 0:
        raise ValueError("No frames extracted")

    if direction == "vertical":
        return np.vstack(frames)
    elif direction == "horizontal":
        return np.hstack(frames)
    else:
        raise ValueError(f"Unsupported direction: {direction}")


def normalize_by_percentile(
    x: np.ndarray,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> tuple[np.ndarray, float, float]:
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
    amp_norm = make_amp_image(img_complex, p_low, p_high, eps)
    return np.clip(amp_norm * gain_linear, 0, 1).astype(np.float32)


def make_amp_log_gain_image(
    img_complex: np.ndarray,
    gain_log: float,
    p_low: float = 1,
    p_high: float = 99,
    eps: float = 1e-12,
) -> np.ndarray:
    amp = np.abs(img_complex)
    amp_db = 20 * np.log10(amp + eps)
    amp_db_norm, _, _ = normalize_by_percentile(amp_db, p_low, p_high, eps)
    return np.clip(amp_db_norm * gain_log, 0, 1).astype(np.float32)


def save_recon_outputs(
    img_complex: np.ndarray,
    base_prefix: Path,
    out_cfg: dict,
    vis_cfg: dict,
    image_mode: str = "all",
) -> list[str]:
    saved_files: list[str] = []

    p_low = vis_cfg["percentile_low"]
    p_high = vis_cfg["percentile_high"]
    eps = vis_cfg["eps"]

    npy_path = base_prefix.with_suffix(".npy")
    iq_png_path = base_prefix.with_suffix(".png")
    amp_png_path = base_prefix.parent / f"{base_prefix.name}_amp.png"
    amp_gain_png_path = base_prefix.parent / f"{base_prefix.name}_amp_gain.png"
    amp_log_gain_png_path = base_prefix.parent / f"{base_prefix.name}_amp_log_gain.png"

    if out_cfg["save_complex_npy"]:
        save_npy(npy_path, img_complex)
        saved_files.append(str(npy_path))

    def want(kind: str) -> bool:
        return image_mode == "all" or image_mode == kind

    if out_cfg["save_iq_png"] and want("iq"):
        iq_vis = make_iq_vis(img_complex, p_low, p_high, eps)
        save_uint8_png(iq_png_path, iq_vis)
        saved_files.append(str(iq_png_path))

    if out_cfg["save_amp_png"] and want("amp"):
        amp_img = make_amp_image(img_complex, p_low, p_high, eps)
        save_uint8_png(amp_png_path, amp_img)
        saved_files.append(str(amp_png_path))

    if out_cfg["save_amp_gain_png"] and want("amp_gain"):
        amp_gain_img = make_amp_gain_image(
            img_complex,
            vis_cfg["gain_linear"],
            p_low,
            p_high,
            eps,
        )
        save_uint8_png(amp_gain_png_path, amp_gain_img)
        saved_files.append(str(amp_gain_png_path))

    if out_cfg["save_amp_log_gain_png"] and want("log_gain"):
        amp_log_gain_img = make_amp_log_gain_image(
            img_complex,
            vis_cfg["gain_log"],
            p_low,
            p_high,
            eps,
        )
        save_uint8_png(amp_log_gain_png_path, amp_log_gain_img)
        saved_files.append(str(amp_log_gain_png_path))

    return saved_files


def process_one_file(
    file_in: str,
    cfg: dict,
    output_dir: str,
    mode: str = "stack",
) -> dict:
    if mode not in {"single", "stack", "both"}:
        raise ValueError(f"Unsupported mode: {mode}")

    result: dict[str, Any] = {
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
        "run_mode": mode,
        "Fs": cfg["signal"]["Fs"],
        "Fc": None,
        "pixel_rate": cfg["signal"]["pixel_rate"],
        "h_total": cfg["signal"]["h_total"],
        "v_total": cfg["signal"]["v_total"],
        "up": cfg["signal"]["up"],
        "down": cfg["signal"]["down"],
        "BW": cfg["processing"]["BW"],
        "numtaps": cfg["processing"]["numtaps"],
        "dc_remove_len": cfg["processing"]["dc_remove_len"],
        "freq_est_m": cfg["processing"]["freq_est_m"],
        "start_offset_samples": cfg["processing"]["start_offset_samples"],
        "remove_dc": cfg["processing"]["remove_dc"],
        "freq_offset_correction": cfg["processing"]["freq_offset_correction"],
        "gain_linear": cfg["visualization"]["gain_linear"],
        "gain_log": cfg["visualization"]["gain_log"],
        "percentile_low": cfg["visualization"]["percentile_low"],
        "percentile_high": cfg["visualization"]["percentile_high"],
        "stack_frame_start": cfg["stacking"]["frame_start"],
        "stack_frame_count": cfg["stacking"]["frame_count"],
        "stack_direction": cfg["stacking"]["direction"],
        "stack_image_mode": cfg["stacking"]["image_mode"],
        "stack_normalization": cfg["stacking"]["normalization"],
        "file_Fs": None,
        "file_Fc": None,
        "capture_time_s": None,
        "total_overrun": None,
        "input_batch_name": None,
    }

    try:
        signal_cfg = cfg["signal"]
        proc_cfg = cfg["processing"]
        out_cfg = cfg["output"]
        vis_cfg = cfg["visualization"]
        stack_cfg = cfg["stacking"]

        rx, file_meta = read_bb_or_mat(file_in, Fs_fallback=signal_cfg["Fs"])
        result["loaded_samples"] = int(len(rx))

        result["file_Fs"] = file_meta.get("Fs")
        result["file_Fc"] = file_meta.get("Fc")
        result["capture_time_s"] = file_meta.get("capture_time_s")
        result["total_overrun"] = file_meta.get("total_overrun")

        capture_meta = file_meta.get("capture_meta", {})
        result["capture_meta"] = capture_meta

        if isinstance(capture_meta, dict):
            flat_meta = flatten_meta(capture_meta, parent_key="capture_meta")
            result.update(flat_meta)

        slide_index = None
        if isinstance(capture_meta, dict):
            slide_index = capture_meta.get("slide_index")

        if slide_index is not None:
            short_name = f"slide{int(slide_index):03d}"
        else:
            short_name = None

        paths = build_output_paths(file_in, output_dir, short_name=short_name)

        Fs_use = float(file_meta.get("Fs", signal_cfg["Fs"]))
        result["Fs"] = Fs_use
        result["Fc"] = file_meta.get("Fc")
        result["input_batch_name"] = Path(file_in).parent.name

        if proc_cfg["remove_dc"]:
            rx = remove_dc(rx, proc_cfg["dc_remove_len"])

        if proc_cfg["freq_offset_correction"]:
            foff = estimate_freq_offset(rx, Fs_use, proc_cfg["freq_est_m"])
            result["freq_offset_hz"] = float(foff)
            rx = apply_freq_offset_correction(rx, Fs_use, foff)
        else:
            result["freq_offset_hz"] = 0.0

        rx_filt = lowpass_filter(
            rx,
            Fs_use,
            proc_cfg["BW"],
            proc_cfg["numtaps"],
        )

        rx_pix = resample_to_pixel_rate(
            rx_filt,
            signal_cfg["up"],
            signal_cfg["down"],
        )
        result["resampled_samples"] = int(len(rx_pix))

        start_offset_samples = proc_cfg["start_offset_samples"]

        available_frames = get_available_frame_count(
            rx_pix,
            signal_cfg["h_total"],
            signal_cfg["v_total"],
            start_offset_samples=start_offset_samples,
        )
        result["available_frames"] = int(available_frames)

        if mode in {"single", "both"}:
            img_complex = extract_frame(
                rx_pix,
                signal_cfg["h_total"],
                signal_cfg["v_total"],
                proc_cfg["frame_idx"],
                start_offset_samples=start_offset_samples,
            )

            base_name = paths["base_name"]
            single_prefix = paths["sample_dir"] / base_name

            saved = save_recon_outputs(
                img_complex=img_complex,
                base_prefix=single_prefix,
                out_cfg=out_cfg,
                vis_cfg=vis_cfg,
                image_mode="all",
            )
            result["saved_files"].extend(saved)

        if mode in {"stack", "both"}:
            frame_start = stack_cfg["frame_start"]
            frame_count = stack_cfg["frame_count"]
            direction = stack_cfg["direction"]

            frame_indices = make_frame_indices(frame_start, frame_count)

            if max(frame_indices) >= available_frames:
                raise ValueError(
                    f"Requested stacked frames {frame_indices}, "
                    f"but only {available_frames} complete frame(s) available."
                )

            img_complex_stacked = make_stacked_complex_image(
                rx_pix=rx_pix,
                h_total=signal_cfg["h_total"],
                v_total=signal_cfg["v_total"],
                frame_start=frame_start,
                frame_count=frame_count,
                direction=direction,
                start_offset_samples=start_offset_samples,
            )

            base_name = paths["base_name"]

            if frame_count == 1:
                stack_prefix = paths["sample_dir"] / base_name
            else:
                stack_prefix = (
                    paths["sample_dir"]
                    / f"{base_name}_stack_{direction}_f{frame_start}_{frame_start + frame_count - 1}"
                )

            saved = save_recon_outputs(
                img_complex=img_complex_stacked,
                base_prefix=stack_prefix,
                out_cfg=out_cfg,
                vis_cfg=vis_cfg,
                image_mode=stack_cfg["image_mode"],
            )
            result["saved_files"].extend(saved)

        if out_cfg["save_meta_json"]:
            meta = {
                "input_file": str(file_in),
                "run_mode": result["run_mode"],
                "loaded_samples": result["loaded_samples"],
                "resampled_samples": result["resampled_samples"],
                "available_frames": result["available_frames"],
                "frame_idx": result["frame_idx"],
                "freq_offset_hz": result["freq_offset_hz"],
                "Fs": result["Fs"],
                "Fc": result["Fc"],
                "capture_time_s": result["capture_time_s"],
                "total_overrun": result["total_overrun"],
                "start_offset_samples": result["start_offset_samples"],
                "stack_frame_start": result["stack_frame_start"],
                "stack_frame_count": result["stack_frame_count"],
                "stack_direction": result["stack_direction"],
                "stack_image_mode": result["stack_image_mode"],
                "input_batch_name": result["input_batch_name"],
                "capture_meta": capture_meta,
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