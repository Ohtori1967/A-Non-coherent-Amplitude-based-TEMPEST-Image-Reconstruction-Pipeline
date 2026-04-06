from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path


def get_default_config() -> dict:
    """Return the default configuration dictionary."""
    return {
        "input": {
            "file_in": "../signals/example.mat",
            "input_dir": "../signals",
            "pattern": "*.mat",
            "recursive": False,
        },
        "output": {
            "output_dir": "../outputs/run_debug",
            "save_complex_npy": True,
            "save_iq_png": True,
            "save_amp_png": True,
            "save_amp_gain_png": True,
            "save_amp_log_gain_png": True,
            "save_meta_json": True,
            "copy_used_config": True,
        },
        "signal": {
            # X310 default
            "Fs": 61_440_000.0,
            "pixel_rate": 148_500_000.0,
            "h_total": 2200,
            "v_total": 1125,
            "up": 2475,
            "down": 1024,
        },
        "processing": {
            "BW": 16_000_000.0,
            "numtaps": 129,
            "dc_remove_len": 10000,
            "freq_est_m": 2000,
            "frame_idx": 0,
            "start_offset_samples": 0,
            "remove_dc": True,
            "freq_offset_correction": True,
        },
        "visualization": {
            "gain_linear": 3.0,
            "gain_log": 1.4,
            "eps": 1e-8,
            "percentile_low": 1,
            "percentile_high": 99,
        },
        "stacking": {
            "frame_start": 0,
            "frame_count": 6,
            "direction": "vertical",
            "image_mode": "all",     # iq / amp / amp_gain / log_gain / all
            "normalization": "global",
        },
    }


def merge_dict(default_cfg: dict, user_cfg: dict) -> dict:
    """Recursively merge user_cfg into default_cfg."""
    merged = deepcopy(default_cfg)

    for key, value in user_cfg.items():
        if (
            key in merged
            and isinstance(merged[key], dict)
            and isinstance(value, dict)
        ):
            merged[key] = merge_dict(merged[key], value)
        else:
            merged[key] = value

    return merged


def _resolve_path_fields(cfg: dict, config_path: str | Path) -> dict:
    """Resolve selected path fields relative to the config file location."""
    config_path = Path(config_path).resolve()
    config_dir = config_path.parent

    path_fields = [
        ("input", "file_in"),
        ("input", "input_dir"),
        ("output", "output_dir"),
    ]

    for section, key in path_fields:
        if section in cfg and key in cfg[section]:
            raw = cfg[section][key]
            if raw is None or raw == "":
                continue
            p = Path(raw)
            if not p.is_absolute():
                p = (config_dir / p).resolve()
            cfg[section][key] = str(p)

    return cfg


def load_config(config_path: str | Path) -> dict:
    """
    Load config from JSON file, merge with defaults, resolve paths,
    validate, and return it.
    """
    config_path = Path(config_path)
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")

    with open(config_path, "r", encoding="utf-8") as f:
        user_cfg = json.load(f)

    cfg = merge_dict(get_default_config(), user_cfg)
    cfg = _resolve_path_fields(cfg, config_path)
    validate_config(cfg)
    return cfg


def validate_config(cfg: dict) -> None:
    """Validate the configuration. Raise ValueError if invalid."""
    signal = cfg["signal"]
    processing = cfg["processing"]
    vis = cfg["visualization"]
    stack_cfg = cfg["stacking"]

    Fs = signal["Fs"]
    pixel_rate = signal["pixel_rate"]
    h_total = signal["h_total"]
    v_total = signal["v_total"]
    up = signal["up"]
    down = signal["down"]

    BW = processing["BW"]
    numtaps = processing["numtaps"]
    dc_remove_len = processing["dc_remove_len"]
    freq_est_m = processing["freq_est_m"]
    frame_idx = processing["frame_idx"]
    start_offset_samples = processing["start_offset_samples"]

    p_low = vis["percentile_low"]
    p_high = vis["percentile_high"]
    eps = vis["eps"]

    frame_start = stack_cfg["frame_start"]
    frame_count = stack_cfg["frame_count"]
    direction = stack_cfg["direction"]
    image_mode = stack_cfg["image_mode"]
    normalization = stack_cfg["normalization"]

    if Fs <= 0:
        raise ValueError("signal.Fs must be > 0")
    if pixel_rate <= 0:
        raise ValueError("signal.pixel_rate must be > 0")
    if h_total <= 0 or v_total <= 0:
        raise ValueError("signal.h_total and signal.v_total must be > 0")
    if up <= 0 or down <= 0:
        raise ValueError("signal.up and signal.down must be > 0")

    if BW <= 0:
        raise ValueError("processing.BW must be > 0")
    if BW >= Fs / 2:
        raise ValueError("processing.BW must be < signal.Fs / 2")

    if numtaps <= 1:
        raise ValueError("processing.numtaps must be > 1")
    if dc_remove_len <= 0:
        raise ValueError("processing.dc_remove_len must be > 0")
    if freq_est_m <= 0:
        raise ValueError("processing.freq_est_m must be > 0")
    if frame_idx < 0:
        raise ValueError("processing.frame_idx must be >= 0")
    if start_offset_samples < 0:
        raise ValueError("processing.start_offset_samples must be >= 0")

    if not isinstance(processing["remove_dc"], bool):
        raise ValueError("processing.remove_dc must be bool")
    if not isinstance(processing["freq_offset_correction"], bool):
        raise ValueError("processing.freq_offset_correction must be bool")

    if not (0 <= p_low < p_high <= 100):
        raise ValueError(
            "visualization.percentile_low and percentile_high must satisfy "
            "0 <= low < high <= 100"
        )
    if eps <= 0:
        raise ValueError("visualization.eps must be > 0")

    if frame_start < 0:
        raise ValueError("stacking.frame_start must be >= 0")
    if frame_count <= 0:
        raise ValueError("stacking.frame_count must be > 0")
    if direction not in {"vertical", "horizontal"}:
        raise ValueError("stacking.direction must be 'vertical' or 'horizontal'")
    if image_mode not in {"iq", "amp", "amp_gain", "log_gain", "all"}:
        raise ValueError(
            "stacking.image_mode must be one of: "
            "'iq', 'amp', 'amp_gain', 'log_gain', 'all'"
        )
    if normalization not in {"global"}:
        raise ValueError("stacking.normalization currently must be 'global'")


def save_config_snapshot(cfg: dict, save_path: str | Path) -> None:
    """Save the actually used configuration into the output directory."""
    save_path = Path(save_path)
    save_path.parent.mkdir(parents=True, exist_ok=True)

    with open(save_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)