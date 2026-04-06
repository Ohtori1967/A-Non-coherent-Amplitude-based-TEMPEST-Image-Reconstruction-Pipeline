from __future__ import annotations

import sys
from pathlib import Path

sys.path.append("./src")

from recon.config_manager import load_config
from recon.batch_runner import batch_process


def main() -> None:
    cfg = load_config("./configs/debug_single.json")

    # "single" / "stack" / "both"
    run_mode = "stack"

    print("===== Loaded Config =====")
    print("input_dir   :", cfg["input"]["input_dir"])
    print("output_dir  :", cfg["output"]["output_dir"])
    print("pattern     :", cfg["input"]["pattern"])
    print("recursive   :", cfg["input"]["recursive"])
    print("run_mode    :", run_mode)

    print("\n===== Signal / Processing Params =====")
    print("Fs          :", cfg["signal"]["Fs"])
    print("pixel_rate  :", cfg["signal"]["pixel_rate"])
    print("h_total     :", cfg["signal"]["h_total"])
    print("v_total     :", cfg["signal"]["v_total"])
    print("up/down     :", cfg["signal"]["up"], "/", cfg["signal"]["down"])
    print("BW          :", cfg["processing"]["BW"])
    print("numtaps     :", cfg["processing"]["numtaps"])
    print("frame_idx   :", cfg["processing"]["frame_idx"])
    print("offset      :", cfg["processing"]["start_offset_samples"])
    print("remove_dc   :", cfg["processing"]["remove_dc"])
    print("foff_corr   :", cfg["processing"]["freq_offset_correction"])

    print("\n===== Stacking Params =====")
    print("frame_start :", cfg["stacking"]["frame_start"])
    print("frame_count :", cfg["stacking"]["frame_count"])
    print("direction   :", cfg["stacking"]["direction"])
    print("image_mode  :", cfg["stacking"]["image_mode"])
    print("norm        :", cfg["stacking"]["normalization"])

    df = batch_process(
        input_dir=cfg["input"]["input_dir"],
        output_dir=cfg["output"]["output_dir"],
        cfg=cfg,
        pattern=cfg["input"]["pattern"],
        recursive=cfg["input"]["recursive"],
        show_progress=True,
        mode=run_mode,
    )

    print("\n===== Batch Summary Head =====")
    if df.empty:
        print("Empty DataFrame")
        return

    cols_to_show = [
        "stem",
        "success",
        "run_mode",
        "loaded_samples",
        "resampled_samples",
        "available_frames",
        "frame_idx",
        "freq_offset_hz",
        "Fs",
        "Fc",
        "capture_time_s",
        "total_overrun",
        "capture_meta.sample_id",
        "capture_meta.slide_index",
        "capture_meta.font_size_pt",
        "capture_meta.sdr_model",
        "capture_meta.antenna_model",
        "capture_meta.test_distance_cm",
        "stack_frame_start",
        "stack_frame_count",
        "stack_direction",
    ]

    existing_cols = [c for c in cols_to_show if c in df.columns]
    print(df[existing_cols].head())

    print("\n===== Statistics =====")
    print("Total files   :", len(df))
    print("Success files :", int(df["success"].sum()))
    print("Failed files  :", int((~df["success"]).sum()))

    if "freq_offset_hz" in df.columns:
        valid_foff = df.loc[df["success"], "freq_offset_hz"].dropna()
        if len(valid_foff) > 0:
            print("Mean foff (Hz):", float(valid_foff.mean()))

    print("\n===== Saved Files Preview =====")
    if "saved_files" in df.columns:
        for idx, row in df.head(3).iterrows():
            print(f"\n[{idx}] {row.get('stem', 'unknown')}")
            saved = row["saved_files"]
            if isinstance(saved, list):
                for p in saved:
                    print("  ", p)
            else:
                print("  ", saved)

    print("\n===== Output Directory =====")
    print(Path(cfg["output"]["output_dir"]).resolve())


if __name__ == "__main__":
    main()