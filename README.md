# fluxnet-shuttle-ecland

Scripts and configuration to run [ecLand](https://www.ecmwf.int/en/research/modelling-systems/land-surface) land-surface model simulations over flux-tower sites discovered live via the [FLUXNET Shuttle](https://github.com/fluxnet/shuttle) — extending beyond the fixed 170-site [PLUMBER2](https://essd.copernicus.org/articles/14/449/2022/) benchmark (see sibling repo [plumber2-ecland](https://github.com/gpbalsamo/plumber2-ecland), which this repo forks most of its `scripts/` from) into the wider, continually-growing pool of sites now available across AmeriFlux, ICOS and TERN.

As of the 2026-08-18 live Shuttle snapshot: **775 sites** (AmeriFlux 381, ICOS 342, TERN 52) vs PLUMBER2's 170 — including biomes/regions PLUMBER2 underrepresents (savanna, Mediterranean shrubland, Sahel, boreal/tundra), which is the actual motivation: a CoFLAME-facing gap around fire-prone and vegetation-stress biomes.

![FLUXNET Shuttle site locations, colored by biome](shuttle_sites_map.png)

Generated with `scripts/plot_sites_map.py --snapshot-csv <listall snapshot>` — the same script (forked as-is from `plumber2-ecland`) that renders that repo's 170-site map, extended with a fourth Barren & Snow/Ice biome group and `DNF`/`CVM` IGBP classes for the sites outside the original PLUMBER2 pool.

## Status (2026-08-18)

**Forcing now exists for the whole live site pool.** A full run on ECMWF HPC (2026-08-18 snapshot, ERA5 gapfilling, `complete` preset, NOAA CO2 fill) produced ecLand-ready forcing for **775 / 775 sites — 5397 site-years**, median 5 years per site, max 31:

| hub | sites | site-years |
|---|---|---|
| AmeriFlux | 381 / 381 | 2513.1 |
| ICOS | 342 / 342 | 2511.1 |
| TERN | 52 / 52 | 373.0 |

By IGBP: GRA 145, CRO 138, WET 115, ENF 114, DBF 80, EBF 44, OSH 40, MF 24, WSA 18, SAV 14, DNF 13, CSH 12, CVM 9, BSV 7, SNO 2 — the fire/vegetation-stress classes that motivate this repo (SAV/WSA/OSH/CSH/GRA) come to **228 sites**, against PLUMBER2's 170 in total.

Gap-fill intensity across all 7750 (file, variable) records, from `reference/qc_report_shuttle-all775-era5.csv`: mild 3755, medium 1603, heavy 1169, complete 1223. Roughly half the delivered data is lightly gap-filled; the heavily-filled remainder is labelled per file and variable rather than mixed in silently. Reaching full coverage does depend on ERA5 — sites vary from near-pure observations to records where pressure and precipitation are largely reanalysis.

What's validated vs. what's still blocked:

**Validated end-to-end, on real data:**
- Live Shuttle inventory pull, IGBP/record-length filtering, and download (`fluxnet-shuttle listall`/`download` + `scripts/filter_candidate_sites.py`) — see `reference/shuttle_pilot20_site_ids.txt` for the current 20-site fire/vegetation-stress pilot shortlist.
- FluxnetLSM conversion of a real downloaded site (ES-LJu, ICOS) to ALMA-CF NetCDF (`scripts/install_fluxnetlsm.R` + `scripts/convert_fluxnetlsm.R`) — variables/dims are byte-identical to an existing PLUMBER2-170 file.
- `scripts/regenerate_forcing.sh` (forked unmodified from `plumber2-ecland`) converts that FluxnetLSM output to ecLand's forcing convention with **no changes needed**. This was the step flagged as the real engineering risk going in; it isn't one for Shuttle-sourced sites.
- The whole download → convert → forcing chain, batched over an arbitrary site list by `scripts/run_forcing_pipeline.sh` (streaming, resumable, parallel — see [Batch-process many sites](#2-batch-process-many-sites)).
- ERA5 gapfilling against the Shuttle's own `*_ERA5_HH_*.csv`: FluxnetLSM's `ERAinterim` path is fully compatible with it despite the product-name difference (columns and half-hour timestamps line up exactly for the join FluxnetLSM does — see `scripts/convert_fluxnetlsm.R`'s header).

**Real findings about the expanded site pool** (not bugs — they shape how you run the pipeline):
- PLUMBER2-style QC screening is strict against sites outside the original pool: ES-LJu's real 21-year record only yielded 2 usable years under statistical gapfilling. Expect similar attrition elsewhere — hence the acceptance presets below, rather than one fixed threshold set.
- FluxnetLSM's default `check_range_action="stop"` discards a site's **entire** multi-year record over a single implausible value anywhere in it; this alone killed SN-Dhr and US-ICt over one bad PA/VPD value from an ERA5 extraction edge case. The `heavy`/`complete` presets use `truncate` instead.
- Because acceptance thresholds only decide what gets *written out* (gapfilling always runs first regardless), the real per-variable gap-fill fraction is recorded in every output file. `scripts/qc_classify.py` reads it back, so how much you trust a period is a filtering decision made *after* processing, not a rerun.
- **Gapfill method dominates yield, far more than the preset does.** The same 775 sites and the same `complete` preset gave 231 sites / 505 files under statistical gapfilling but **775 / 775** under ERA5. Statistical filling cannot close long gaps, and FluxnetLSM's `missing_met` threshold (default 0) then discards the whole year.
- **CO2 was silently costing 97 sites.** `missing_met=0` drops a year if *any* met variable still has a gap, and CO2 is the one met variable the Shuttle's ERA5 file cannot fill (`ERAinterim_variable=NA` in FluxnetLSM's own schema — reanalysis surface files carry no atmospheric CO2). Those sites were being discarded over a variable ecLand is not driven by here (`LEAIRCO2COUP=.FALSE.`; CO2 appears only as model output). `scripts/fill_co2_from_noaa.py` fills it from the NOAA GML monthly global mean, flagged QC=3 so it still reports as gap-filled — recovering all 97 sites and 264 site-years without touching any acceptance threshold.
- **One site is blocked by upstream metadata, not by data.** FluxnetLSM's packaged `Site_metadata.csv` marks CZ-BK2 `Exclude=TRUE` with `Exclude_reason=NA`, aborting conversion before any data is read. Verified it converts to a complete 7-year record; `build_site_metadata.py` carries a documented override (`EXCLUDE_OVERRIDES`), reversible with `--respect-upstream-excludes`.

**Blocked, not yet solved:**
- **No script generates `clim/<group>/surfclim_<site>.nc` / `surfinit_<site>.nc`** (soil, vegetation cover fractions, orography, LAI climatology — ecLand's non-meteorological static inputs) for a new site coordinate. `plumber2-ecland`'s versions of these files were produced externally and only ever fetched from Git LFS; FluxnetLSM doesn't produce them either (it only converts met/flux data).

This is the only real blocker. ecLand itself runs locally on macOS — `scripts/run_parallel_local.sh` already produced the full 170-site PLUMBER2 benchmark on this machine (GPU-accelerated, 8 concurrent workers; see `plumber2-ecland/benchmark/dashboards/`), so once surfclim/surfinit exist for a site, running ecLand and postprocessing/benchmarking it is not an open problem here.

## Pipeline

```
scripts/install_fluxnetlsm.R (once per machine)      # R + FluxnetLSM, with a documented sf/lutz workaround

fluxnet-shuttle listall                              # live site inventory -> snapshot CSV
  -> scripts/build_site_metadata.py                   # FluxnetLSM's 874-site table + Shuttle sites -> merged site CSV
  -> scripts/fetch_noaa_co2.py                        # NOAA GML monthly CO2 -> CO2 fallback table (once)
  -> scripts/filter_candidate_sites.py                # IGBP/record-length filter, exclude PLUMBER2-170 (optional)
  -> scripts/run_forcing_pipeline.sh                  # batch driver, per site:
       fluxnet-shuttle download                       #   per-site zip -> FLUXMET (+ optional ERA5) HH CSV
       -> scripts/fill_co2_from_noaa.py               #   fill missing CO2 (-C), which ERA5 cannot supply
       -> scripts/convert_fluxnetlsm.R                #   FLUXMET CSV -> ALMA-CF Met/Flux NetCDF (--preset, --gapfill)
       -> scripts/regenerate_forcing.sh               #   -> ecLand forcing convention (lon/lat/time, PSurf/Rainf)
  -> scripts/qc_classify.py                           # post-hoc: real per-variable gap-fill % -> mild/medium/heavy/complete
  -> [BLOCKED: surfclim/surfinit for the new coordinate — see Status above]
  -> scripts/ecland_run_experiment.sh / run_parallel_local.sh   # runs locally on macOS (or HPC via ecland_run.sh)
  -> scripts/postproc.py                               # raw ecLand output -> common schema
  -> scripts/benchmark.py                              # score vs. flux obs -> dashboard
```

`run_forcing_pipeline.sh` is the normal entry point; `convert_fluxnetlsm.R` and `regenerate_forcing.sh` can also be invoked directly for a single site (see [Single site](#3-single-site-manual-invocation)).

## Repository layout

```
fluxnet-shuttle-ecland/
├── clim/<group>/            # ecLand static/climatology inputs (NetCDF, Git LFS) — BLOCKED for new sites, see Status
├── forcing/<group>/         # Meteorological forcing, ecLand-ready (NetCDF, Git LFS)
├── flux/<group>/            # Observed flux (evaluation) data, FLUXNET2015-schema (NetCDF, Git LFS)
├── namelists/               # ecLand namelist configuration files (forked as-is from plumber2-ecland)
├── reference/                # Site-ID lists and site metadata
│   ├── plumber2_170_site_ids.txt   # Copy of plumber2-ecland's 170-site list, used as the exclude-list
│   ├── shuttle_pilot20_site_ids.txt # Current fire/vegetation-stress pilot shortlist (20 sites)
│   ├── shuttle_pilot20_candidates.csv # The same shortlist with hub/coords/IGBP/record-length columns
│   ├── site_metadata_merged.csv    # FluxnetLSM's Site_metadata.csv + the 2026-08-18 Shuttle sites
│   │                                 (1349 sites), for convert_fluxnetlsm.R --site-csv
│   ├── noaa_gml_co2_monthly.csv    # NOAA GML monthly global mean CO2, the CO2 gapfill fallback
│   └── qc_report_shuttle-all775-era5.csv  # Gap-fill intensity per (file, variable) for the 775-site run
├── scripts/
│   ├── run_forcing_pipeline.sh     # NEW: batch Shuttle -> forcing driver (streaming, resumable, parallel)
│   ├── submit_forcing_pipeline_slurm.sh # NEW: submit the batch driver to SLURM as a job array
│   ├── build_site_metadata.py      # NEW: build reference/site_metadata_merged.csv
│   ├── fetch_noaa_co2.py           # NEW: fetch NOAA GML monthly global mean CO2
│   ├── fill_co2_from_noaa.py       # NEW: fill a FLUXMET CSV's missing CO2 from that table
│   ├── filter_candidate_sites.py   # NEW: filter a Shuttle snapshot CSV to candidates
│   ├── install_fluxnetlsm.R        # NEW: install FluxnetLSM (documents the sf/lutz build workaround)
│   ├── convert_fluxnetlsm.R        # NEW: FLUXMET CSV -> ALMA-CF NetCDF via FluxnetLSM, with the
│   │                                 mild/medium/heavy/complete acceptance presets
│   ├── qc_classify.py              # NEW: classify written forcing files by real per-variable gap-fill %
│   ├── regenerate_forcing.sh       # forked as-is (regenerate_plumber2_forcing.sh) -- no changes needed
│   ├── plot_sites_map.py           # forked as-is -- already supports --snapshot-csv for Shuttle sites
│   ├── postproc.py                 # forked + generalized (postproc_plumber2.py): --experiment-name replaces
│   │                                 the hardcoded "PLUMBER2" tag in output filenames/metadata
│   ├── benchmark.py                # forked + generalized (benchmark_plumber2.py): --experiment-name,
│   │                                 --run-name replace the hardcoded "PLUMBER2"/all170/best42 assumptions
│   ├── check_dates.py              # forked + generalized (check_plumber2_dates.py): --experiment-name
│   ├── run_and_proc.sh / run_and_proc_macos.sh   # forked + generalized (GROUP/EXPERIMENT_NAME vars)
│   ├── run_parallel_local.sh       # forked + generalized (run_parallel_local_macos.sh): -g GROUP now required
│   ├── ecland_run.sh               # forked + generalized HPC job template (edit GROUP/paths per run)
│   └── ecland_run_experiment.sh, ecland_run_model.sh, ecland_run_test.sh, ecland_retrieve.sh,
│       ecland_retrieve_lfs.sh, ecland_parse_commandline.sh, ecland_runtime.sh, ecland_validate.sh,
│       ecland_validate_stats.py, ecland_extract_stats.py, ecland_create_namelist.py, ecland-launch,
│       align_clim_latlon.sh, run_sbatch.sh, dashboard_template.html  # forked as-is -- already
│                                     parameterized by GROUP/site, nothing PLUMBER2-specific
├── output/                  # Model output — excluded from git
├── postprocessed/           # Post-processed output — excluded from git
└── benchmark/                # Metrics/JSON/dashboard per experiment
```

## Getting started

Clone with Git LFS support so NetCDF pointer files resolve correctly (`.nc`/`.nc4`/`.cdf` under `clim/`, `forcing/`, `flux/` are LFS-tracked — see `.gitattributes` — matching `plumber2-ecland`'s convention):

```bash
# Install Git LFS if not already available
# brew install git-lfs
git lfs install

git clone git@github.com:gpbalsamo/fluxnet-shuttle-ecland.git
cd fluxnet-shuttle-ecland
```

### 1. Pull the live Shuttle inventory, site metadata, and a candidate shortlist

```bash
pip install fluxnet-shuttle   # or: pip install git+https://github.com/fluxnet/shuttle.git
fluxnet-shuttle listall       # -> fluxnet_shuttle_snapshot_<timestamp>.csv

Rscript scripts/install_fluxnetlsm.R   # once per machine; needs: brew install r netcdf gdal

# Merge FluxnetLSM's bundled Site_metadata.csv with the snapshot. Required for
# any site outside the original FLUXNET2015 pool: FluxnetLSM's own table stops
# at ~874 mostly pre-2017 sites and *silently* converts unknown sites with NA
# lat/lon/IGBP. Re-run whenever you take a newer snapshot.
python3 scripts/build_site_metadata.py fluxnet_shuttle_snapshot_*.csv \
  --out reference/site_metadata_merged.csv

# CO2 fallback table. CO2 is the one met variable ERA5 gapfilling cannot supply,
# and FluxnetLSM discards any year with a residual met gap -- so without this,
# sites with intermittent CO2 are lost over a variable ecLand is not driven by.
python3 scripts/fetch_noaa_co2.py --out reference/noaa_gml_co2_monthly.csv
```

`build_site_metadata.py` also applies the documented `EXCLUDE_OVERRIDES` in its source, which un-excludes sites FluxnetLSM's table blocks without a stated reason (currently just CZ-BK2, verified to convert cleanly). Pass `--respect-upstream-excludes` to honour the upstream flags instead.

Optionally narrow the full inventory to a shortlist (skip this to process every site in the snapshot):

```bash
python3 scripts/filter_candidate_sites.py fluxnet_shuttle_snapshot_*.csv \
  --igbp SAV WSA OSH CSH GRA \
  --exclude-file reference/plumber2_170_site_ids.txt \
  --min-years 5 \
  --top 20 \
  --out reference/shuttle_pilot20_candidates.csv
```

`--igbp` selects fire/vegetation-stress biomes (Savanna, Woody Savanna, Open/Closed Shrubland, Grassland); drop it to keep all IGBP classes. See `python3 scripts/filter_candidate_sites.py --help` for ranking/hub-priority options.

`--out` always writes a **CSV** (site_id, hub, coordinates, IGBP, record years, download link) — it is not a site-ID list. The ranked table is also printed to stdout, since the shipped `reference/shuttle_pilot20_site_ids.txt` was hand-picked from it for biome/geographic diversity rather than taken verbatim off the top.

### 2. Batch-process many sites

`scripts/run_forcing_pipeline.sh` drives download → FluxnetLSM conversion → forcing adaptation for every site in a list, writing `forcing/<group>/met_insituHT_<site>_<years>.nc` (and the matching observed flux files under `flux/<group>/`):

```bash
scripts/run_forcing_pipeline.sh \
  -f fluxnet_shuttle_snapshot_*.csv \
  -g shuttle-pilot20 \
  -S reference/shuttle_pilot20_site_ids.txt \
  -c reference/site_metadata_merged.csv \
  -C reference/noaa_gml_co2_monthly.csv \
  -P heavy -G erainterim -j 4
```

Omit `-S` to process every site in the snapshot; `#` comments, blank lines and duplicates in the site list are ignored, so hand-maintained lists like the shipped shortlist can be passed directly. Key behaviours:

- **Disk-safe.** One site at a time per worker, with each site's raw download (up to ~500 MB) deleted as soon as it's consumed — all 775 sites' zips at once would need >100 GB. Final outputs are a few MB per site.
- **Resumable.** Every finished site writes `scripts/work/forcing_pipeline_<group>/status/<site>` (`OK`, `NODOWNLOAD`, `BADZIP`, `NOFLUXMET`, `NOERA5`, `NOYEARS`, `NOMET`, `ADAPT_FAILED`, `ERROR`) and is skipped on re-invocation. Transient failures are told apart from genuine no-data verdicts, so a network blip can be retried by deleting just those status files:

  ```bash
  grep -lxE 'NODOWNLOAD|BADZIP' scripts/work/forcing_pipeline_shuttle-pilot20/status/* | xargs rm
  ```

  then re-running the same command. Per-site logs are in `scripts/work/forcing_pipeline_<group>/logs/<site>.log`.
- **`-P` acceptance preset** — `mild | medium` (default) `| heavy | complete`, a bundle of FluxnetLSM's own thresholds (`gapfill_met_tier1`, `missing_flux`, `min_yrs`, `check_range_action`). For a fixed gapfill method, a looser preset yields a strict superset of the periods a stricter one yields. `heavy`/`complete` switch `check_range_action` to `truncate`, which is what keeps a single implausible value from discarding a site's whole record.
- **`-G` gapfilling** — `statistical` (default, no extra input) or `erainterim`, which also extracts the site's `*_ERA5_HH_*.csv` from the same download and passes it through. Flux variables always gapfill statistically; FluxnetLSM supports nothing else for them. This choice dominates yield: 231 sites vs 775 on the same pool and preset.
- **`-C` CO2 fill** — fills missing CO2 from `reference/noaa_gml_co2_monthly.csv` before conversion, flagged QC=3 so it is still counted as gap-filled. Needed because ERA5 has no CO2 to give; without it 97 sites produced nothing at all.
- A site can yield **several disjoint qualifying periods** (e.g. 2009 and 2011–2013 separately); every one is written, not just the longest.
- **`-W`** moves the work directory (downloads, logs, status) off the repo filesystem — see [Running on HPC](#running-on-hpc-slurm).

### 2b. Running on HPC (SLURM)

`scripts/submit_forcing_pipeline_slurm.sh` submits the same pipeline as a job array: the site list is split across `-a` array tasks, each running `run_forcing_pipeline.sh` with `-j` workers, all sharing one work directory. Concurrent sites = `-a` × `-j`.

```bash
# One-off setup (see Requirements for what these need)
module load R/4.5.3
R_LIBS_USER=$PERM/R/library/4.5 Rscript scripts/install_fluxnetlsm.R
python3 -m venv $PERM/venv-shuttle
$PERM/venv-shuttle/bin/pip install git+https://github.com/fluxnet/shuttle.git netCDF4

# Submit
scripts/submit_forcing_pipeline_slurm.sh \
  -f $SCRATCH/fluxnet_shuttle_snapshot_*.csv \
  -g shuttle-all775 \
  -c reference/site_metadata_merged.csv \
  -C reference/noaa_gml_co2_monthly.csv \
  -P complete -G erainterim -a 8 -j 4
```

That is the exact configuration behind the 775-site result in [Status](#status-2026-08-18): ~47 minutes wall-clock at 8x4, plus a short second pass for the CO2-recovered sites.

Add `-n` to write the job script and print it without submitting. Validated 2026-08-18 on ECMWF's Atos HPC (`gpil`, qos `nf`): the 20-site pilot ran 5×4 in ~4 minutes.

- **Slices are disjoint and the status directory is shared**, so the array is resumable exactly like an interactive run: re-submit with the same `-g` and every site already recorded is skipped, no matter which task did it.
- **Work directory defaults to `$SCRATCH`.** Each worker stages a ~500 MB download, so this wants a fast, roomy filesystem — not the repo's. Outputs (`forcing/`, `flux/`) still land in the repo.
- **The batch environment is not the login environment.** `SBATCH_EXPORT=NONE` on ECMWF, so the job script loads R and NCO itself and prepends the venv to `PATH`; override with `R_MODULE`, `NCO_MODULE`, `R_LIBS_DIR`, `SHUTTLE_VENV`. A preflight check fails the task in seconds if `Rscript`, `fluxnet-shuttle`, `ncks` or `unzip` is missing, rather than after a queue of downloads.
- **Compute nodes need outbound HTTPS**, since every task downloads from ICOS/AmeriFlux/TERN. They have it at ECMWF; elsewhere the download step may have to run where the network is.
- **Concurrency is a courtesy question.** The `-a 4 -j 4` default is 16 simultaneous downloads from the data hubs. Raise it knowingly.

### 3. Single site (manual invocation)

Useful for debugging one site or inspecting FluxnetLSM's intermediate output:

```bash
fluxnet-shuttle download -f fluxnet_shuttle_snapshot_*.csv -s ES-LJu -o downloads/

Rscript scripts/convert_fluxnetlsm.R \
  --site=ES-LJu \
  --infile=downloads/ES-LJu/EUF_ES-LJu_FLUXNET_FLUXMET_HH_*.csv \
  --outdir=fluxnetlsm_out \
  --site-csv=reference/site_metadata_merged.csv

ORIG_DIR=fluxnetlsm_out/Nc_files/Met OUT_DIR=forcing/shuttle-pilot20 \
  scripts/regenerate_forcing.sh
```

`convert_fluxnetlsm.R` also takes `--preset`, `--gapfill`/`--era-file`, and explicit `--min-years`/`--check-range-action` overrides; see its header for what each preset changes.

### 4. Check how gap-filled the result actually is

The preset decides what gets written; it says nothing about how much of a written period is real observation. FluxnetLSM records the true per-variable `Missing_%`/`Gap-filled_%`/`Gapfilling_method` in every file, and these survive into the final forcing files, so this is a post-hoc filter — no reprocessing needed:

```bash
python3 scripts/qc_classify.py forcing/shuttle-pilot20 --out qc_report.csv
```

Each (file, variable) is bucketed into the same `mild`/`medium`/`heavy`/`complete` bands as the acceptance presets, letting you keep a permissively-admitted period while still knowing to distrust it.

### 5. Plot the candidate sites

```bash
python3 scripts/plot_sites_map.py --snapshot-csv fluxnet_shuttle_snapshot_*.csv --output sites_map.png
```

### 6. Run ecLand and postprocess/benchmark

Blocked until `clim/shuttle-pilot20/surfclim_<site>.nc` / `surfinit_<site>.nc` exist for these sites (see Status above). Once they do, the remaining steps are unchanged from `plumber2-ecland`'s workflow, just pointed at a different `GROUP` and `--experiment-name`:

```bash
scripts/ecland_run_experiment.sh -g shuttle-pilot20 -t insitu -x <path_to_ecland_executable>
python3 scripts/postproc.py --experiment-name shuttle-pilot20 --overwrite
python3 scripts/benchmark.py --model-dir benchmark/models/shuttle-pilot20 \
  --out-dir benchmark/dashboards/shuttle-pilot20 --experiment-name shuttle-pilot20
```

## Requirements

- ecLand executable (built separately; see [ECMWF ecLand](https://github.com/ecmwf-ifs/ecland)) — runs on ECMWF HPC or locally on macOS (already validated for the 170-site PLUMBER2 benchmark, see `plumber2-ecland`'s README).
- Python: `numpy`, `xarray`, `netCDF4`, `pandas`, plus the [`fluxnet-shuttle`](https://github.com/fluxnet/shuttle) CLI.
- R + [FluxnetLSM](https://github.com/aukkola/FluxnetLSM) — `scripts/install_fluxnetlsm.R` installs both (needs `brew install r netcdf gdal` first on macOS).
- NCO tools (`ncrename`, `ncks`, `ncatted`, `nccopy`) for `scripts/regenerate_forcing.sh`, and `unzip` for `scripts/run_forcing_pipeline.sh`.
- Enough scratch space for `scripts/work/` while the pipeline runs: a few GB is plenty at `-j 4`, since each site's download is deleted as soon as it's converted.

## License

Scripts forked from `plumber2-ecland`: Copyright 2023– ECMWF, licensed under the [Apache Licence Version 2.0](http://www.apache.org/licenses/LICENSE-2.0). New scripts in this repo follow the same license.
