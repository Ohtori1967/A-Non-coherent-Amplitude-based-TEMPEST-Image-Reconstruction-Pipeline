from __future__ import annotations

from pathlib import Path
from os import PathLike

import pandas as pd
from tqdm.auto import tqdm
from tqdm.std import tqdm as tqdm_type

from recon.tempest_io import ensure_dir
from recon.tempest_recon import process_one_file
from recon.config_manager import save_config_snapshot


def find_input_files(
    input_dir: str | Path,
    pattern: str = "*.mat",
    recursive: bool = False,
    exclude_dir_names: list[str] | None = None,
) -> list[Path]:
    """
    Find input files under input_dir using glob pattern.
    """
    input_dir = Path(input_dir)
    if not input_dir.exists():
        raise FileNotFoundError(f"Input directory not found: {input_dir}")

    if exclude_dir_names is None:
        exclude_dir_names = ["checkpoints"]

    exclude_dir_names_lower = {name.lower() for name in exclude_dir_names}

    if recursive:
        files = sorted(input_dir.rglob(pattern))
    else:
        files = sorted(input_dir.glob(pattern))

    filtered: list[Path] = []
    for f in files:
        if not f.is_file():
            continue

        parts_lower = {part.lower() for part in f.parts}
        if parts_lower & exclude_dir_names_lower:
            continue

        filtered.append(f)

    return filtered


def find_input_batches(
    input_root_dir: str | Path,
    exclude_dir_names: list[str] | None = None,
) -> list[Path]:
    """
    Find batch subdirectories directly under input_root_dir.
    """
    input_root_dir = Path(input_root_dir)
    if not input_root_dir.exists():
        raise FileNotFoundError(f"Input root directory not found: {input_root_dir}")

    if exclude_dir_names is None:
        exclude_dir_names = ["checkpoints"]

    exclude_dir_names_lower = {name.lower() for name in exclude_dir_names}

    batch_dirs: list[Path] = []
    for p in sorted(input_root_dir.iterdir()):
        if not p.is_dir():
            continue
        if p.name.lower() in exclude_dir_names_lower:
            continue
        batch_dirs.append(p)

    return batch_dirs


def save_batch_summary(df: pd.DataFrame, output_dir: str | Path) -> str:
    """
    Save batch summary as CSV and return its path.
    """
    output_dir = ensure_dir(output_dir)
    csv_path = output_dir / "batch_summary.csv"
    df.to_csv(csv_path, index=False, encoding="utf-8-sig")
    return str(csv_path)


def batch_process(
    input_dir: str | PathLike[str],
    output_dir: str | PathLike[str],
    cfg: dict,
    pattern: str = "*.mat",
    recursive: bool = False,
    show_progress: bool = True,
    mode: str = "stack",
) -> pd.DataFrame:
    """
    Batch process all matching files in one input_dir.
    """
    input_dir = Path(input_dir)
    output_dir = ensure_dir(output_dir)

    if cfg["output"].get("copy_used_config", False):
        save_config_snapshot(cfg, output_dir / "used_config.json")

    files = find_input_files(
        input_dir,
        pattern=pattern,
        recursive=recursive,
        exclude_dir_names=cfg["input"].get("exclude_dir_names", ["checkpoints"]),
    )

    if len(files) == 0:
        print(f"No files found in: {input_dir} | pattern={pattern}")
        return pd.DataFrame()

    print(f"Found {len(files)} file(s).")
    results: list[dict] = []

    success_count = 0
    fail_count = 0

    pbar: tqdm_type | None = None
    if show_progress:
        pbar = tqdm(files, desc="Batch processing", unit="file", dynamic_ncols=True)
        iterable = pbar
    else:
        iterable = files

    for idx, file_in in enumerate(iterable, start=1):
        if pbar is not None:
            pbar.set_postfix({
                "file": file_in.name,
                "ok": success_count,
                "fail": fail_count,
            })
        else:
            print(f"\n[{idx}/{len(files)}] Processing: {file_in.name}")

        res = process_one_file(
            file_in=str(file_in),
            cfg=cfg,
            output_dir=str(output_dir),
            mode=mode,
        )
        results.append(res)

        if res.get("success", False):
            success_count += 1

            if pbar is None:
                sample_id = res.get("capture_meta.sample_id", None)
                slide_index = res.get("capture_meta.slide_index", None)
                print(
                    f"  OK | "
                    f"sample={sample_id} | "
                    f"slide={slide_index} | "
                    f"loaded={res.get('loaded_samples')} | "
                    f"resampled={res.get('resampled_samples')} | "
                    f"frames={res.get('available_frames')} | "
                    f"foff={res.get('freq_offset_hz')}"
                )
        else:
            fail_count += 1
            if pbar is None:
                print(f"  FAIL | {res.get('error')}")

        if pbar is not None:
            pbar.set_postfix({
                "file": file_in.name,
                "ok": success_count,
                "fail": fail_count,
            })

    df = pd.DataFrame(results)

    preferred_order = [
        "stem",
        "success",
        "run_mode",
        "input_batch_name",
        "capture_meta.sample_id",
        "capture_meta.slide_index",
        "capture_meta.font_size_pt",
        "capture_meta.sdr_model",
        "capture_meta.antenna_model",
        "loaded_samples",
        "resampled_samples",
        "available_frames",
        "freq_offset_hz",
        "Fs",
        "Fc",
        "capture_time_s",
        "total_overrun",
        "stack_frame_start",
        "stack_frame_count",
        "stack_direction",
        "stack_image_mode",
        "saved_files",
        "error",
    ]
    existing_first = [c for c in preferred_order if c in df.columns]
    remaining = [c for c in df.columns if c not in existing_first]
    if len(existing_first) > 0:
        df = df[existing_first + remaining]

    csv_path = save_batch_summary(df, output_dir)

    print("\nBatch finished.")
    print(f"Success: {success_count}/{len(df)}")
    print(f"Fail   : {fail_count}/{len(df)}")
    print(f"Summary saved to: {csv_path}")

    return df


def batch_process_collection(
    input_root_dir: str | PathLike[str],
    output_root_dir: str | PathLike[str],
    cfg: dict,
    pattern: str = "*.mat",
    recursive: bool = True,
    show_progress: bool = True,
    mode: str = "stack",
) -> dict[str, pd.DataFrame]:
    """
    Process multiple batch folders under one input root directory.

    Each input batch folder gets a same-name output folder under output_root_dir.
    """
    input_root_dir = Path(input_root_dir)
    output_root_dir = ensure_dir(output_root_dir)

    batch_dirs = find_input_batches(
        input_root_dir,
        exclude_dir_names=cfg["input"].get("exclude_dir_names", ["checkpoints"]),
    )

    if len(batch_dirs) == 0:
        print(f"No batch folders found in: {input_root_dir}")
        return {}

    print(f"Found {len(batch_dirs)} batch folder(s).")

    all_results: dict[str, pd.DataFrame] = {}

    for batch_dir in batch_dirs:
        batch_name = batch_dir.name
        batch_output_dir = output_root_dir / batch_name

        print("\n" + "=" * 60)
        print(f"Processing batch folder: {batch_name}")
        print(f"Input : {batch_dir}")
        print(f"Output: {batch_output_dir}")
        print("=" * 60)

        df = batch_process(
            input_dir=batch_dir,
            output_dir=batch_output_dir,
            cfg=cfg,
            pattern=pattern,
            recursive=recursive,
            show_progress=show_progress,
            mode=mode,
        )

        if not df.empty:
            df["input_batch_name"] = batch_name

        all_results[batch_name] = df

    valid_dfs = [df for df in all_results.values() if not df.empty]
    if len(valid_dfs) > 0:
        collection_df = pd.concat(valid_dfs, ignore_index=True)
        collection_csv = output_root_dir / "collection_summary.csv"
        collection_df.to_csv(collection_csv, index=False, encoding="utf-8-sig")
        print(f"\nCollection summary saved to: {collection_csv}")

    return all_results