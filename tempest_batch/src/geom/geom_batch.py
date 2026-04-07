from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from tqdm.auto import tqdm

from geom.geom_io import (
    apply_debug_limits,
    apply_slide_limit,
    build_block_output_name,
    build_geom_json_name,
    find_geometry_source,
    find_variant_images,
    list_batch_dirs,
    list_slide_dirs,
    save_json,
)
from geom.geom_shear import DEFAULT_SHEAR_PARAMS, estimate_shear_for_image
from geom.geom_anchor import DEFAULT_ANCHOR_PARAMS
from geom.geom_correct import (
    correct_one_variant_with_geometry,
    detect_geometry_from_amp,
    save_png01,
)


def _to_builtin(obj: Any) -> Any:
    """Convert numpy/scalar/container objects to JSON-safe builtin types."""
    if isinstance(obj, (np.floating,)):
        return float(obj)
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, np.ndarray):
        return obj.tolist()
    if isinstance(obj, tuple):
        return [_to_builtin(x) for x in obj]
    if isinstance(obj, list):
        return [_to_builtin(x) for x in obj]
    if isinstance(obj, dict):
        return {str(k): _to_builtin(v) for k, v in obj.items()}
    return obj


def estimate_s0_for_slide(
    amp_img_path: Path,
    shear_params: dict[str, Any],
) -> float:
    """
    Estimate one slide-level s0 from the amp geometry source.
    """
    res = estimate_shear_for_image(amp_img_path, params=shear_params)
    if np.isfinite(res["global_slope_median"]):
        return float(res["global_slope_median"])
    raise RuntimeError(f"Failed to estimate slide-level s0 for {amp_img_path}")


def estimate_s0_for_batch(
    slide_dirs: list[Path],
    geometry_source_suffix: str,
    shear_params: dict[str, Any],
) -> float:
    """
    Estimate one batch-level s0 by aggregating all valid slide-level slope estimates
    within the batch. The batch median is used as the final s0.
    """
    s0_list: list[float] = []

    for slide_dir in slide_dirs:
        amp_img_path = find_geometry_source(slide_dir, geometry_source_suffix)
        if amp_img_path is None:
            continue

        try:
            s0 = estimate_s0_for_slide(amp_img_path, shear_params)
            if np.isfinite(s0):
                s0_list.append(float(s0))
        except Exception:
            continue

    if len(s0_list) == 0:
        raise RuntimeError("Failed to estimate batch-level s0: no valid slide slopes found")

    return float(np.median(np.asarray(s0_list, dtype=np.float64)))


def choose_s0_for_slide(
    amp_img_path: Path,
    config: dict[str, Any],
    shear_params: dict[str, Any],
    batch_s0: float | None = None,
) -> float:
    """
    Choose the shear slope for one slide according to config.

    Supported modes:
    - fixed: use config["fixed_s0"]
    - per_slide: estimate s0 from this slide only
    - per_batch: use batch_s0 pre-estimated for the whole batch
    """
    s0_mode = str(config.get("s0_mode", "fixed")).lower()

    if s0_mode == "fixed":
        return float(config["fixed_s0"])

    if s0_mode == "per_slide":
        return estimate_s0_for_slide(amp_img_path, shear_params)

    if s0_mode == "per_batch":
        if batch_s0 is None:
            raise RuntimeError("s0_mode='per_batch' requires a valid batch_s0")
        return float(batch_s0)

    raise ValueError(f"Unsupported s0_mode: {s0_mode}")


def _print_config_summary(config: dict[str, Any]) -> None:
    """Print a concise batch-run summary for debugging."""
    print("[geom] ===== Geometry Correction Config =====")
    print(f"[geom] input_root_dir          = {config['input_root_dir']}")
    print(f"[geom] batch_dir_glob          = {config.get('batch_dir_glob', 'output_*')}")
    print(f"[geom] slide_dir_glob          = {config.get('slide_dir_glob', 'slide*')}")
    print(f"[geom] geometry_source_suffix  = {config['geometry_source_suffix']}")
    print(f"[geom] variant_suffixes        = {config['variant_suffixes']}")
    print(f"[geom] frame_width             = {config['frame_width']}")
    print(f"[geom] frame_height            = {config['frame_height']}")
    print(f"[geom] s0_mode                 = {config.get('s0_mode', 'fixed')}")
    print(f"[geom] fixed_s0                = {config.get('fixed_s0', None)}")
    print(f"[geom] export_blocks           = {config.get('export_blocks', [0])}")
    print(f"[geom] save_geometry_json      = {config.get('save_geometry_json', True)}")
    print(f"[geom] save_before_shear       = {config.get('save_before_shear', False)}")
    print(f"[geom] overwrite               = {config.get('overwrite', True)}")
    print(f"[geom] limit_batches           = {config.get('limit_batches', None)}")
    print(f"[geom] limit_slides_per_batch  = {config.get('limit_slides_per_batch', None)}")
    print("[geom] =====================================")


def run_geometry_correction_batch(
    config: dict[str, Any],
    shear_params: dict[str, Any] | None = None,
    anchor_params: dict[str, Any] | None = None,
):
    """
    Run geometry correction for all discovered batch directories.

    Workflow:
    1. Discover batch folders under input_root_dir.
    2. Discover slide folders in each batch.
    3. Use amp grayscale image as geometry source.
    4. Detect anchor coordinates on amp image.
    5. Reuse the same geometry on iq / amp / amp_gain / amp_log_gain images.
    6. Save corrected block images and geometry JSON into each slide folder.
    7. Save one global CSV summary under input_root_dir.
    """
    shear_params = DEFAULT_SHEAR_PARAMS if shear_params is None else shear_params
    anchor_params = DEFAULT_ANCHOR_PARAMS if anchor_params is None else anchor_params

    input_root_dir = Path(config["input_root_dir"])
    batch_dir_glob = str(config.get("batch_dir_glob", "output_*"))
    slide_dir_glob = str(config.get("slide_dir_glob", "slide*"))

    geometry_source_suffix = str(config["geometry_source_suffix"])
    variant_suffixes = dict(config["variant_suffixes"])

    frame_width = int(config["frame_width"])
    frame_height = int(config["frame_height"])

    export_blocks = list(config.get("export_blocks", [0]))
    overwrite = bool(config.get("overwrite", True))
    save_geometry_json = bool(config.get("save_geometry_json", True))
    save_before_shear = bool(config.get("save_before_shear", False))

    limit_batches = config.get("limit_batches", None)
    limit_slides_per_batch = config.get("limit_slides_per_batch", None)

    _print_config_summary(config)

    batch_dirs = list_batch_dirs(input_root_dir, batch_dir_glob=batch_dir_glob)
    batch_dirs = apply_debug_limits(batch_dirs, limit_batches=limit_batches)

    print(f"[geom] found {len(batch_dirs)} batch directories")
    for i, bd in enumerate(batch_dirs[:10], 1):
        print(f"[geom]   batch[{i}] = {bd.name}")

    summary_rows: list[dict[str, Any]] = []

    for batch_dir in tqdm(batch_dirs, desc="Geometry batches"):
        slide_dirs = list_slide_dirs(batch_dir, slide_dir_glob=slide_dir_glob)
        slide_dirs = apply_slide_limit(
            slide_dirs,
            limit_slides_per_batch=limit_slides_per_batch,
        )

        print(f"[geom] batch = {batch_dir.name}, slides = {len(slide_dirs)}")

        s0_mode = str(config.get("s0_mode", "fixed")).lower()
        batch_s0: float | None = None

        if s0_mode == "per_batch":
            batch_s0 = estimate_s0_for_batch(
                slide_dirs=slide_dirs,
                geometry_source_suffix=geometry_source_suffix,
                shear_params=shear_params,
            )
            print(f"[geom] batch-level s0 for {batch_dir.name} = {batch_s0:.12f}")

        for slide_dir in tqdm(slide_dirs, desc=f"{batch_dir.name}", leave=True):
            slide_id = slide_dir.name

            amp_img_path = find_geometry_source(slide_dir, geometry_source_suffix)
            if amp_img_path is None:
                print(f"[geom][skip] {batch_dir.name}/{slide_id}: no geometry source")
                summary_rows.append(
                    {
                        "batch_dir": batch_dir.name,
                        "slide_id": slide_id,
                        "status": "skip_no_geometry_source",
                        "s0_mode": s0_mode,
                        "geometry_source": "",
                    }
                )
                continue

            variant_imgs = find_variant_images(slide_dir, variant_suffixes)
            if len(variant_imgs) == 0:
                print(f"[geom][skip] {batch_dir.name}/{slide_id}: no variant images")
                summary_rows.append(
                    {
                        "batch_dir": batch_dir.name,
                        "slide_id": slide_id,
                        "status": "skip_no_variant_images",
                        "s0_mode": s0_mode,
                        "geometry_source": amp_img_path.name,
                    }
                )
                continue

            try:
                s0 = choose_s0_for_slide(
                    amp_img_path=amp_img_path,
                    config=config,
                    shear_params=shear_params,
                    batch_s0=batch_s0,
                )

                anchor_full = detect_geometry_from_amp(
                    amp_img_path=amp_img_path,
                    s0=s0,
                    anchor_params=anchor_params,
                )

                block_geoms: list[dict[str, Any]] = []
                block_map: dict[int, dict[str, Any]] = {}

                for br in anchor_full["block_results"]:
                    block_id = int(br["block_id"])
                    ar = br["anchor_res"]

                    if ar is None:
                        continue

                    start_index = int(
                        round(ar["A_crop"][1]) * frame_width + round(ar["A_crop"][0])
                    )

                    block_info = {
                        "block_id": block_id,
                        "block": _to_builtin(br["block"]),
                        "A_ref": _to_builtin(ar["A_ref"]),
                        "A_crop": _to_builtin(ar["A_crop"]),
                        "start_index": start_index,
                        "y_top": _to_builtin(ar["y_top"]),
                        "b": _to_builtin(ar["b"]),
                        "side": ar["side"],
                        "polarity": _to_builtin(ar["polarity"]),
                        "score": _to_builtin(ar["score"]),
                    }

                    block_geoms.append(block_info)
                    block_map[block_id] = block_info

                if save_geometry_json:
                    geom_json = {
                        "batch_dir": batch_dir.name,
                        "slide_id": slide_id,
                        "geometry_source": amp_img_path.name,
                        "frame_width": frame_width,
                        "frame_height": frame_height,
                        "s0": float(s0),
                        "s0_mode": s0_mode,
                        "blocks": block_geoms,
                    }
                    save_json(slide_dir / build_geom_json_name(slide_id), geom_json)

                exported_count = 0

                for block_id in export_blocks:
                    if block_id not in block_map:
                        continue

                    a_crop = tuple(block_map[block_id]["A_crop"])

                    for variant_name, variant_path in variant_imgs.items():
                        out_name = build_block_output_name(slide_id, block_id, variant_name)
                        out_path = slide_dir / out_name

                        if out_path.exists() and (not overwrite):
                            continue

                        corr = correct_one_variant_with_geometry(
                            img_path=variant_path,
                            a_crop=a_crop,
                            s0=s0,
                            frame_width=frame_width,
                            frame_height=frame_height,
                        )

                        if save_before_shear:
                            out_before = slide_dir / out_name.replace(".png", "_before_shear.png")
                            save_png01(out_before, corr["frame_before_shear"])

                        save_png01(out_path, corr["frame_after_shear"])
                        exported_count += 1

                summary_rows.append(
                    {
                        "batch_dir": batch_dir.name,
                        "slide_id": slide_id,
                        "status": "ok",
                        "s0_mode": s0_mode,
                        "geometry_source": amp_img_path.name,
                        "s0": float(s0),
                        "n_detected_blocks": len(block_geoms),
                        "n_export_blocks": len(export_blocks),
                        "n_variant_images": len(variant_imgs),
                        "n_exported_files": exported_count,
                    }
                )

            except Exception as e:
                print(f"[geom][error] {batch_dir.name}/{slide_id}: {e}")
                summary_rows.append(
                    {
                        "batch_dir": batch_dir.name,
                        "slide_id": slide_id,
                        "status": "error",
                        "s0_mode": s0_mode,
                        "geometry_source": amp_img_path.name,
                        "error": str(e),
                    }
                )

    df_summary = pd.DataFrame(summary_rows)
    summary_csv = input_root_dir / "geom_batch_summary.csv"
    df_summary.to_csv(summary_csv, index=False, encoding="utf-8-sig")
    print(f"[geom] summary saved to: {summary_csv}")

    return summary_rows
