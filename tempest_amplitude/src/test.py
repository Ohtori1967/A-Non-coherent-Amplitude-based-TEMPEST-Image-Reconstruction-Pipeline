from __future__ import annotations

import sys

sys.path.append("./src")

from config_manager import load_config
from batch_runner import batch_process


cfg = load_config("./configs/batch_default.json")

df = batch_process(
    input_dir=cfg["input"]["input_dir"],
    output_dir=cfg["output"]["output_dir"],
    cfg=cfg,
    pattern=cfg["input"]["pattern"],
    recursive=cfg["input"]["recursive"],
)

print("\n===== Batch Summary Head =====")
print(df.head())

if not df.empty:
    print("\n===== Statistics =====")
    print("Total files   :", len(df))
    print("Success files :", int(df["success"].sum()))
    print("Failed files  :", int((~df["success"]).sum()))

    if "freq_offset_hz" in df.columns:
        valid_foff = df.loc[df["success"], "freq_offset_hz"].dropna()
        if len(valid_foff) > 0:
            print("Mean foff (Hz):", float(valid_foff.mean()))