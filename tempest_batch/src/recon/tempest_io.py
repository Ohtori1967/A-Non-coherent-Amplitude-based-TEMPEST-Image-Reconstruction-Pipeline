from __future__ import annotations

import json
from pathlib import Path
from os import PathLike
from typing import Any

import h5py
import imageio.v2 as imageio
import numpy as np


def ensure_dir(path: str | PathLike[str]) -> Path:
    """Ensure a directory exists and return it as a Path."""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def _to_py_scalar(x: Any) -> Any:
    """Convert numpy scalar-like objects to Python scalars when possible."""
    if isinstance(x, np.generic):
        return x.item()
    return x


def _decode_matlab_char_array(arr: np.ndarray) -> str:
    """
    Decode MATLAB char array stored in HDF5.
    Supports common uint16 / uint8 string-like arrays.
    """
    arr = np.asarray(arr)
    if arr.size == 0:
        return ""

    arr = np.squeeze(arr)

    if arr.dtype.kind in {"u", "i"}:
        flat = arr.flatten()
        chars = [chr(int(c)) for c in flat if int(c) != 0]
        return "".join(chars).strip()

    if arr.dtype.kind in {"S", "U"}:
        return "".join(arr.astype(str).flatten()).strip()

    return str(arr)


def _dataset_to_complex(d: Any) -> np.ndarray:
    """
    Convert a dataset into 1D complex64 IQ.
    Supported:
      - native complex
      - structured dtype with real/imag
      - Nx2
      - 2xN
      - row/column vector
    """
    d = np.array(d)

    if np.iscomplexobj(d):
        return d.squeeze().astype(np.complex64)

    if (
        isinstance(d.dtype, np.dtype)
        and d.dtype.fields is not None
        and {"real", "imag"}.issubset(d.dtype.fields.keys())
    ):
        real = d["real"]
        imag = d["imag"]
        return (real + 1j * imag).astype(np.complex64).squeeze()

    if d.ndim == 2 and d.shape[1] == 2:
        return (d[:, 0] + 1j * d[:, 1]).astype(np.complex64)

    if d.ndim == 2 and d.shape[0] == 2:
        return (d[0, :] + 1j * d[1, :]).astype(np.complex64)

    if d.ndim == 2 and (d.shape[0] == 1 or d.shape[1] == 1):
        return d.flatten().astype(np.complex64)

    raise ValueError(
        f"Unsupported dataset shape/dtype for complex IQ: "
        f"shape={d.shape}, dtype={d.dtype}"
    )


def _read_h5_scalar_or_text(obj: Any) -> Any:
    """
    Read a simple HDF5 dataset/group recursively into Python objects.
    This is intentionally conservative and aimed at MATLAB -v7.3 files
    produced by the current capture pipeline.
    """
    if isinstance(obj, h5py.Dataset):
        arr = np.array(obj)

        if arr.shape == () or arr.size == 1:
            if arr.dtype.kind in {"u", "i", "f", "b"}:
                return _to_py_scalar(arr.reshape(-1)[0])

        if arr.dtype.kind in {"u", "i", "S", "U"}:
            return _decode_matlab_char_array(arr)

        return arr.tolist()

    if isinstance(obj, h5py.Group):
        out: dict[str, Any] = {}
        for k in obj.keys():
            child = obj.get(k)
            if child is not None:
                out[k] = _read_h5_scalar_or_text(child)
        return out

    return None


def _extract_top_level_meta(f: h5py.File, Fs_fallback: float | None = None) -> dict:
    """Extract metadata from top-level datasets/groups when available."""
    meta: dict[str, Any] = {}

    scalar_keys = [
        "Fs",
        "Fc",
        "capture_time_s",
        "total_overrun",
        "warmup_overrun",
        "sample_margin",
        "gain_dB",
        "samplesPerFrame",
        "masterClockRate",
        "decimationFactor",
        "warmup_frames",
        "theoretical_samples",
        "total_len",
        "elapsed_s",
    ]

    for key in scalar_keys:
        if key in f:
            obj = f.get(key)
            if obj is not None:
                try:
                    meta[key] = _read_h5_scalar_or_text(obj)
                except Exception:
                    pass

    if "Fs" not in meta and Fs_fallback is not None:
        meta["Fs"] = float(Fs_fallback)

    if "meta" in f:
        obj = f.get("meta")
        if obj is not None:
            try:
                meta["capture_meta"] = _read_h5_scalar_or_text(obj)
            except Exception:
                meta["capture_meta"] = {}

    return meta


def read_bb_or_mat(
    fname: str | Path,
    Fs_fallback: float | None = None,
) -> tuple[np.ndarray, dict]:
    """
    Read .mat or .bb file and return:
        (iq_complex64_1d, meta_dict)

    Supported cases:
      - .mat with dataset 'iq'
      - .mat with dataset 'x'
      - .mat/.bb with dataset '/BasebandData/IQData'
    """
    fname = Path(fname)
    if not fname.exists():
        raise FileNotFoundError(f"Input file not found: {fname}")

    suffix = fname.suffix.lower()

    if suffix == ".mat":
        with h5py.File(fname, "r") as f:
            keys = list(f.keys())
            meta = _extract_top_level_meta(f, Fs_fallback=Fs_fallback)

            if "iq" in keys:
                obj = f.get("iq")
                if obj is None:
                    raise ValueError("Key 'iq' exists but returned None")
                rx = _dataset_to_complex(obj)
                return rx, meta

            if "x" in keys:
                obj = f.get("x")
                if obj is None:
                    raise ValueError("Key 'x' exists but returned None")
                rx = _dataset_to_complex(obj)
                return rx, meta

            obj = f.get("/BasebandData/IQData")
            if obj is not None:
                iq = np.array(obj)
                if iq.ndim != 2 or iq.shape[1] != 2:
                    raise ValueError(
                        f"Unexpected /BasebandData/IQData shape: {iq.shape}"
                    )
                rx = (iq[:, 0] + 1j * iq[:, 1]).astype(np.complex64)
                return rx, meta

            baseband_group = f.get("BasebandData")
            if isinstance(baseband_group, h5py.Group):
                iq_obj = baseband_group.get("IQData")
                if iq_obj is not None:
                    iq = np.array(iq_obj)
                    if iq.ndim != 2 or iq.shape[1] != 2:
                        raise ValueError(
                            f"Unexpected BasebandData/IQData shape: {iq.shape}"
                        )
                    rx = (iq[:, 0] + 1j * iq[:, 1]).astype(np.complex64)
                    return rx, meta

            raise ValueError(
                "Cannot find dataset 'iq', 'x', or '/BasebandData/IQData'. "
                f"Top-level keys: {keys}"
            )

    elif suffix == ".bb":
        with h5py.File(fname, "r") as f:
            obj = f.get("/BasebandData/IQData")
            if obj is None:
                raise ValueError(
                    "Cannot find dataset '/BasebandData/IQData' in .bb file"
                )

            iq = np.array(obj)
            if iq.ndim != 2 or iq.shape[1] != 2:
                raise ValueError(
                    f"Unexpected /BasebandData/IQData shape: {iq.shape}"
                )

            meta = {}
            if Fs_fallback is not None:
                meta["Fs"] = float(Fs_fallback)

            rx = (iq[:, 0] + 1j * iq[:, 1]).astype(np.complex64)
            return rx, meta

    else:
        raise ValueError(f"Unsupported file extension: {suffix}")


def make_json_safe(obj: Any) -> Any:
    """Recursively convert objects into JSON-safe Python types."""
    if isinstance(obj, dict):
        return {str(k): make_json_safe(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [make_json_safe(v) for v in obj]
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, np.generic):
        return obj.item()
    if isinstance(obj, Path):
        return str(obj)
    return obj


def flatten_meta(
    d: dict[str, Any],
    parent_key: str = "",
    sep: str = ".",
) -> dict[str, Any]:
    """
    Flatten nested dictionaries.
    Example:
      {"capture_meta": {"sample_id": 3}} -> {"capture_meta.sample_id": 3}
    """
    items: dict[str, Any] = {}
    for k, v in d.items():
        new_key = f"{parent_key}{sep}{k}" if parent_key else str(k)
        if isinstance(v, dict):
            items.update(flatten_meta(v, new_key, sep=sep))
        else:
            items[new_key] = v
    return items


def save_uint8_png(path: str | Path, img01: np.ndarray) -> None:
    """
    Save an image whose values are in [0,1] as uint8 PNG.
    Supports 2D grayscale or 3D RGB arrays.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    img01 = np.asarray(img01)
    img_u8 = np.clip(img01 * 255.0, 0, 255).astype(np.uint8)
    imageio.imwrite(path, img_u8)


def save_npy(path: str | Path, arr: np.ndarray) -> None:
    """Save numpy array to .npy file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    np.save(path, arr)


def save_json(path: str | Path, obj: dict) -> None:
    """Save dictionary to JSON file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(make_json_safe(obj), f, ensure_ascii=False, indent=2)


def build_output_paths(
    input_file: str | Path,
    output_dir: str | Path,
    short_name: str | None = None,
) -> dict:
    """
    Build output paths for one input file.

    If short_name is given, use it for folder/file naming.
    Otherwise fall back to input stem.
    """
    input_file = Path(input_file)
    output_dir = Path(output_dir)

    stem = input_file.stem
    base_name = short_name if short_name else stem

    sample_dir = output_dir / base_name
    sample_dir.mkdir(parents=True, exist_ok=True)

    return {
        "sample_dir": sample_dir,
        "stem": stem,
        "base_name": base_name,
        "npy": sample_dir / f"{base_name}.npy",
        "iq_png": sample_dir / f"{base_name}.png",
        "amp_png": sample_dir / f"{base_name}_amp.png",
        "amp_gain_png": sample_dir / f"{base_name}_amp_gain.png",
        "amp_log_gain_png": sample_dir / f"{base_name}_amp_log_gain.png",
        "meta_json": sample_dir / f"{base_name}_meta.json",
    }
    
