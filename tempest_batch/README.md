# TEMPEST Reconstruction Toolkit

A lightweight workflow for debugging, batch reconstruction, and result inspection of captured TEMPEST signal data.

---

## Project Structure

```text
project_root/
├─ configs/
│  ├─ debug_single.json
│  └─ batch_default.json
├─ notebooks/
│  ├─ 01_single_file_debug.ipynb
│  ├─ 02_batch_run.ipynb
│  └─ 03_result_inspection.ipynb
├─ src/
│  ├─ config_manager.py
│  ├─ tempest_io.py
│  ├─ tempest_recon.py
│  └─ batch_runner.py
└─ outputs/
````

---

## Workflow Overview

This project is organized into three notebooks.

### 1. `01_single_file_debug.ipynb`

Use this notebook to debug one captured signal file.

Typical tasks:

* load one `.mat` file
* adjust `start_offset_samples`
* change `frame_count`
* switch `image_mode`
* inspect saved outputs and metadata

Use this notebook when:

* one sample looks wrong
* frame alignment needs tuning
* different visualization modes need comparison

---

### 2. `02_batch_run.ipynb`

Use this notebook to run reconstruction for multiple captured signal batch folders.

Typical tasks:

* scan all signal batch folders under one input root directory
* process all `.mat` files automatically
* create same-name output folders under one output root directory
* generate:

  * per-batch `batch_summary.csv`
  * global `collection_summary.csv`

Use this notebook when:

* running a full experiment set
* generating reconstruction outputs for many slides
* organizing results by acquisition batch

---

### 3. `03_result_inspection.ipynb`

Use this notebook to inspect and filter batch results.

Typical tasks:

* load `collection_summary.csv`
* inspect success and failure rows
* filter by metadata
* preview saved file paths
* export filtered subsets

Useful filter fields include:

* `input_batch_name`
* `capture_meta.sample_id`
* `capture_meta.slide_index`
* `capture_meta.font_size_pt`
* `total_overrun`

Use this notebook when:

* reviewing a full reconstruction run
* selecting representative samples
* preparing figures or experiment notes

---

## Recommended Usage Order

1. Run `01_single_file_debug.ipynb`
2. Run `02_batch_run.ipynb`
3. Run `03_result_inspection.ipynb`

---

## Configuration Files

### `configs/debug_single.json`

Recommended for single-file debugging.

Typical settings:

* one input file
* detailed output enabled
* `frame_count = 1` or a small value
* `image_mode = "all"`

### `configs/batch_default.json`

Recommended for batch reconstruction.

Typical settings:

* input root directory containing many signal batch folders
* one output root directory
* compact output enabled
* `image_mode = "log_gain"`

---

## Input and Output Layout

### Input

Captured signal files are stored under signal batch folders, for example:

```text
E:/UsersData/Desktop/usrp_signal_capture/outputs/output_16x9_20pt_pages_0001-0100_CF_742.500MHz_FS_61.440MSPS_20260402_131046
```

### Output

Reconstruction results are stored under the configured output root directory.

Each signal batch folder gets a same-name output folder.

Example:

```text
outputs/
└─ output_16x9_20pt_pages_0001-0100_CF_742.500MHz_FS_61.440MSPS_20260402_131046/
   ├─ batch_summary.csv
   ├─ slide001/
   │  ├─ slide001_amp.png
   │  ├─ slide001_amp_gain.png
   │  ├─ slide001_amp_log_gain.png
   │  └─ slide001_meta.json
   ├─ slide002/
   └─ ...
```

---

## Naming Rules

### Slide-level output

Short names are used for per-slide outputs.

Examples:

* `slide001_amp.png`
* `slide001_amp_gain.png`
* `slide001_amp_log_gain.png`
* `slide001_meta.json`

This avoids repeating the long original capture filename in every output file.

### Batch-level output

Batch folder names are preserved from the original capture folders, so experiment context remains clear at the directory level.

---

## Reconstruction Notes

* `frame_count = 1` is treated as the single-frame special case.
* `frame_count > 1` produces stacked output.
* `checkpoints` folders are skipped during batch reconstruction.
* metadata from captured `.mat` files is preserved in:

  * per-sample `meta.json`
  * per-batch `batch_summary.csv`
  * global `collection_summary.csv`

---

## Main Parameters

### Processing

* `start_offset_samples`: shift the reconstruction start position
* `BW`: low-pass bandwidth
* `numtaps`: FIR tap number
* `remove_dc`: enable DC removal
* `freq_offset_correction`: enable frequency offset correction

### Stacking

* `frame_start`: first frame index
* `frame_count`: number of stacked frames
* `direction`: `vertical` or `horizontal`
* `image_mode`: `iq`, `amp`, `amp_gain`, `log_gain`, or `all`

---

## Typical Debug Strategy

If one result looks wrong:

1. open `01_single_file_debug.ipynb`
2. set `frame_count = 1`
3. adjust `start_offset_samples`
4. compare `image_mode = "all"` outputs
5. confirm metadata and saved paths
6. return to batch mode after parameters look reasonable

---

## Typical Batch Strategy

For large-scale reconstruction:

1. set `input_root_dir` in `batch_default.json`
2. set one output root directory
3. use `run_mode = "stack"`
4. choose a compact output mode such as:

   * `image_mode = "log_gain"`
   * only `save_amp_log_gain_png = true`
5. run `02_batch_run.ipynb`
6. inspect `collection_summary.csv` in `03_result_inspection.ipynb`

---

## Summary

This toolkit separates the workflow into three stages:

* **debug one sample**
* **run all batches**
* **inspect and filter results**

This keeps reconstruction work reproducible, scalable, and easier to maintain.
