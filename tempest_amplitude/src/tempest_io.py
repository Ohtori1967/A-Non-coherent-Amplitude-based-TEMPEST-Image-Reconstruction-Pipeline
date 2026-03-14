from __future__ import annotations

import json
from pathlib import Path
from os import PathLike

import h5py
import imageio.v2 as imageio
import numpy as np

def ensure_dir(path: str | PathLike[str]) -> Path:
    """Ensure a directory exists and return it as a Path."""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def read_bb_or_mat(fname: str | Path) -> np.ndarray:
    """
    Read .mat or .bb file and return a 1D complex64 IQ vector.
    Supported cases:
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

            if "x" in keys:
                d = np.array(f["x"])

                # Case A: native complex
                if np.iscomplexobj(d):
                    return d.squeeze().astype(np.complex64)

                # Case B: structured dtype with real/imag fields
                if (
                    isinstance(d.dtype, np.dtype)
                    and d.dtype.fields is not None
                    and {"real", "imag"}.issubset(d.dtype.fields.keys())
                ):
                    real = d["real"]
                    imag = d["imag"]
                    return (real + 1j * imag).astype(np.complex64).squeeze()

                # Case C: Nx2
                if d.ndim == 2 and d.shape[1] == 2:
                    return (d[:, 0] + 1j * d[:, 1]).astype(np.complex64)

                # Case D: 2xN
                if d.ndim == 2 and d.shape[0] == 2:
                    return (d[0, :] + 1j * d[1, :]).astype(np.complex64)

                # Case E: row/column vector
                if d.ndim == 2 and (d.shape[0] == 1 or d.shape[1] == 1):
                    return d.flatten().astype(np.complex64)

                raise ValueError(
                    f"Unsupported dataset shape/dtype for 'x': "
                    f"shape={d.shape}, dtype={d.dtype}"
                )

            if "/BasebandData/IQData" in f:
                iq = np.array(f["/BasebandData/IQData"])
                if iq.ndim != 2 or iq.shape[1] != 2:
                    raise ValueError(
                        f"Unexpected /BasebandData/IQData shape: {iq.shape}"
                    )
                return (iq[:, 0] + 1j * iq[:, 1]).astype(np.complex64)

            raise ValueError(
                "Cannot find dataset 'x' or '/BasebandData/IQData'. "
                f"Top-level keys: {keys}"
            )

    elif suffix == ".bb":
        with h5py.File(fname, "r") as f:
            if "/BasebandData/IQData" not in f:
                raise ValueError(
                    "Cannot find dataset '/BasebandData/IQData' in .bb file"
                )

            iq = np.array(f["/BasebandData/IQData"])
            if iq.ndim != 2 or iq.shape[1] != 2:
                raise ValueError(
                    f"Unexpected /BasebandData/IQData shape: {iq.shape}"
                )

            return (iq[:, 0] + 1j * iq[:, 1]).astype(np.complex64)

    else:
        raise ValueError(f"Unsupported file extension: {suffix}")


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
        json.dump(obj, f, ensure_ascii=False, indent=2)


def build_output_paths(input_file: str | Path, output_dir: str | Path) -> dict:
    """
    Build a standard set of output paths for one input file.

    Example return:
    {
        "sample_dir": Path(...),
        "stem": "fileA",
        "npy": Path(...),
        "iq_png": Path(...),
        "amp_png": Path(...),
        "amp_gain_png": Path(...),
        "amp_log_gain_png": Path(...),
        "meta_json": Path(...)
    }
    """
    input_file = Path(input_file)
    output_dir = Path(output_dir)

    stem = input_file.stem
    sample_dir = output_dir / stem
    sample_dir.mkdir(parents=True, exist_ok=True)

    return {
        "sample_dir": sample_dir,
        "stem": stem,
        "npy": sample_dir / f"{stem}.npy",
        "iq_png": sample_dir / f"{stem}.png",
        "amp_png": sample_dir / f"{stem}_amp.png",
        "amp_gain_png": sample_dir / f"{stem}_amp_gain.png",
        "amp_log_gain_png": sample_dir / f"{stem}_amp_log_gain.png",
        "meta_json": sample_dir / f"{stem}_meta.json",
    }