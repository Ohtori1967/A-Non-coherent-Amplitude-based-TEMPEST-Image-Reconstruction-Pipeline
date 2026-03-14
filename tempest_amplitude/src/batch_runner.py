from __future__ import annotations

from pathlib import Path
from os import PathLike
import pandas as pd
from tqdm.auto import tqdm
from tqdm.std import tqdm as tqdm_type

from tempest_io import ensure_dir
from tempest_recon import process_one_file
from config_manager import save_config_snapshot


def find_input_files(
    input_dir: str | Path,
    pattern: str = "*.mat",
    recursive: bool = False,
) -> list[Path]:
    """
    Find input files under input_dir using glob pattern.
    """
    input_dir = Path(input_dir)
    if not input_dir.exists():
        raise FileNotFoundError(f"Input directory not found: {input_dir}")

    if recursive:
        files = sorted(input_dir.rglob(pattern))
    else:
        files = sorted(input_dir.glob(pattern))

    return [f for f in files if f.is_file()]


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
) -> pd.DataFrame:
    """
    Batch process all matching files in input_dir.

    Args:
        input_dir: Directory containing input files.
        output_dir: Directory for outputs.
        cfg: Configuration dictionary.
        pattern: Glob pattern, e.g. "*.mat" or "*.bb".
        recursive: Whether to search recursively.
        show_progress: Whether to show tqdm progress bar.

    Returns:
        pandas.DataFrame with one row per file.
    """
    input_dir = Path(input_dir)
    output_dir = ensure_dir(output_dir)

    if cfg["output"].get("copy_used_config", False):
        save_config_snapshot(cfg, output_dir / "used_config.json")

    files = find_input_files(input_dir, pattern=pattern, recursive=recursive)

    if len(files) == 0:
        print(f"No files found in: {input_dir} | pattern={pattern}")
        return pd.DataFrame()

    print(f"Found {len(files)} file(s).")
    results = []

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
        )
        results.append(res)

        if res["success"]:
            success_count += 1
            if pbar is None:
                print(
                    f"  OK | "
                    f"loaded={res['loaded_samples']} | "
                    f"resampled={res['resampled_samples']} | "
                    f"frames={res['available_frames']} | "
                    f"frame_idx={res['frame_idx']} | "
                    f"foff={res['freq_offset_hz']:.2f} Hz"
                )
        else:
            fail_count += 1
            if pbar is None:
                print(f"  FAIL | {res['error']}")

        if pbar is not None:
            pbar.set_postfix({
                "file": file_in.name,
                "ok": success_count,
                "fail": fail_count,
            })

    df = pd.DataFrame(results)
    csv_path = save_batch_summary(df, output_dir)

    print("\nBatch finished.")
    print(f"Success: {success_count}/{len(df)}")
    print(f"Fail   : {fail_count}/{len(df)}")
    print(f"Summary saved to: {csv_path}")

    return df