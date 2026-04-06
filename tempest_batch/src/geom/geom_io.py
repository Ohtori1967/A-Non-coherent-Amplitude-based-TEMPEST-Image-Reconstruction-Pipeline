from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def ensure_dir(path: str | Path) -> Path:
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, data: dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def list_batch_dirs(root_dir: str | Path, batch_dir_glob: str = "output_*") -> list[Path]:
    root = Path(root_dir)
    if not root.exists():
        raise FileNotFoundError(f"input_root_dir does not exist: {root}")
    return sorted([p for p in root.glob(batch_dir_glob) if p.is_dir()])


def list_slide_dirs(batch_dir: str | Path, slide_dir_glob: str = "slide*") -> list[Path]:
    batch_dir = Path(batch_dir)
    return sorted([p for p in batch_dir.glob(slide_dir_glob) if p.is_dir()])


def find_geometry_source(slide_dir: str | Path, geometry_source_suffix: str) -> Path | None:
    slide_dir = Path(slide_dir)
    matches = sorted(slide_dir.glob(f"*{geometry_source_suffix}"))
    return matches[0] if matches else None


def find_variant_images(slide_dir: str | Path, variant_suffixes: dict[str, str]) -> dict[str, Path]:
    slide_dir = Path(slide_dir)
    out: dict[str, Path] = {}

    for variant_name, suffix in variant_suffixes.items():
        matches = sorted(slide_dir.glob(f"*{suffix}"))
        if matches:
            out[variant_name] = matches[0]

    return out


def build_block_output_name(slide_id: str, block_id: int, variant_name: str) -> str:
    return f"{slide_id}_block{block_id}_{variant_name}.png"


def build_geom_json_name(slide_id: str) -> str:
    return f"{slide_id}_blocks_geom.json"


def apply_debug_limits(
    batch_dirs: list[Path],
    limit_batches: int | None,
) -> list[Path]:
    if limit_batches is None:
        return batch_dirs
    return batch_dirs[: max(0, int(limit_batches))]


def apply_slide_limit(
    slide_dirs: list[Path],
    limit_slides_per_batch: int | None,
) -> list[Path]:
    if limit_slides_per_batch is None:
        return slide_dirs
    return slide_dirs[: max(0, int(limit_slides_per_batch))]