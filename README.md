# fluxnet-shuttle-ecland

Scripts and configuration to run [ecLand](https://www.ecmwf.int/en/research/modelling-systems/land-surface) land-surface model simulations over flux-tower sites discovered live via the [FLUXNET Shuttle](https://github.com/fluxnet/shuttle) — extending beyond the fixed 170-site [PLUMBER2](https://essd.copernicus.org/articles/14/449/2022/) benchmark (see sibling repo [plumber2-ecland](https://github.com/gpbalsamo/plumber2-ecland), which this repo forks most of its `scripts/` from) into the wider, continually-growing pool of sites now available across AmeriFlux, ICOS and TERN.

As of the 2026-08-17 live Shuttle snapshot: **775 sites** (AmeriFlux 381, ICOS 342, TERN 52) vs PLUMBER2's 170 — including biomes/regions PLUMBER2 underrepresents (savanna, Mediterranean shrubland, Sahel, boreal/tundra), which is the actual motivation: a CoFLAME-facing gap around fire-prone and vegetation-stress biomes.

## Status (2026-08-17)

This is a pilot, not a finished benchmark. What's real and validated vs. what's still blocked:

**Validated end-to-end, on real data, on this machine:**
- Live Shuttle inventory pull, IGBP/record-length filtering, and download (`fluxnet-shuttle listall`/`download` + `scripts/filter_candidate_sites.py`) — see `reference/shuttle_pilot20_site_ids.txt` for the current 20-site fire/vegetation-stress pilot shortlist.
- FluxnetLSM conversion of a real downloaded site (ES-LJu, ICOS) to ALMA-CF NetCDF (`scripts/install_fluxnetlsm.R` + `scripts/convert_fluxnetlsm.R`) — variables/dims are byte-identical to an existing PLUMBER2-170 file.
- `scripts/regenerate_forcing.sh` (forked unmodified from `plumber2-ecland`) converts that FluxnetLSM output to ecLand's forcing convention with **no changes needed**. This was the step flagged as the real engineering risk going in; it isn't one for Shuttle-sourced sites.
- Real evidence that PLUMBER2-style QC screening is strict against the expanded pool: ES-LJu's real 21-year record only yielded 2 usable years under statistical gapfilling. Expect similar attrition elsewhere — thresholds may need revisiting, or accept shorter per-site records at scale.

**Blocked, not yet solved:**
- **No script generates `clim/<group>/surfclim_<site>.nc` / `surfinit_<site>.nc`** (soil, vegetation cover fractions, orography, LAI climatology — ecLand's non-meteorological static inputs) for a new site coordinate. `plumber2-ecland`'s versions of these files were produced externally and only ever fetched from Git LFS; FluxnetLSM doesn't produce them either (it only converts met/flux data). Gianpaolo has asked Gabriele Arduini (ECMWF) about this directly.
- **ecLand itself needs an ECMWF HPC build** (see `scripts/ecland_run.sh`'s module loads) — nothing here can actually run ecLand outside that environment; everything above was validated as far as testable off-HPC.

## Pipeline

```
fluxnet-shuttle listall                              # live site inventory -> snapshot CSV
  -> scripts/filter_candidate_sites.py                # IGBP/record-length filter, exclude PLUMBER2-170
  -> fluxnet-shuttle download                         # per-site FLUXMET CSV (FLUXNET2015-schema columns)
  -> scripts/install_fluxnetlsm.R (once)               # R + FluxnetLSM, with a documented sf/lutz workaround
  -> scripts/convert_fluxnetlsm.R                      # FLUXMET CSV -> ALMA-CF Met/Flux NetCDF
  -> scripts/regenerate_forcing.sh                     # -> ecLand forcing convention (lon/lat/time, PSurf/Rainf)
  -> [BLOCKED: surfclim/surfinit for the new coordinate — see Status above]
  -> scripts/ecland_run_experiment.sh                  # [ECMWF HPC only]
  -> scripts/postproc.py                               # raw ecLand output -> common schema
  -> scripts/benchmark.py                              # score vs. flux obs -> dashboard
```

## Repository layout

```
fluxnet-shuttle-ecland/
├── clim/<group>/            # ecLand static/climatology inputs (NetCDF) — BLOCKED for new sites, see Status
├── forcing/<group>/         # Meteorological forcing, ecLand-ready (NetCDF)
├── flux/<group>/            # Observed flux (evaluation) data, FLUXNET2015-schema
├── namelists/               # ecLand namelist configuration files (forked as-is from plumber2-ecland)
├── reference/                # Site-ID lists
│   ├── plumber2_170_site_ids.txt   # Copy of plumber2-ecland's 170-site list, used as the exclude-list
│   └── shuttle_pilot20_site_ids.txt # Current fire/vegetation-stress pilot shortlist (20 sites)
├── scripts/
│   ├── filter_candidate_sites.py   # NEW: filter a Shuttle snapshot CSV to candidates
│   ├── install_fluxnetlsm.R        # NEW: install FluxnetLSM (documents the sf/lutz build workaround)
│   ├── convert_fluxnetlsm.R        # NEW: FLUXMET CSV -> ALMA-CF NetCDF via FluxnetLSM
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

### 1. Pull the live Shuttle inventory and build a candidate shortlist

```bash
pip install fluxnet-shuttle   # or: pip install git+https://github.com/fluxnet/shuttle.git
fluxnet-shuttle listall       # -> fluxnet_shuttle_snapshot_<timestamp>.csv

python3 scripts/filter_candidate_sites.py fluxnet_shuttle_snapshot_*.csv \
  --igbp SAV WSA OSH CSH GRA \
  --exclude-file reference/plumber2_170_site_ids.txt \
  --min-years 5 \
  --top 20 \
  --out reference/shuttle_pilot20_site_ids.txt
```

`--igbp` selects fire/vegetation-stress biomes (Savanna, Woody Savanna, Open/Closed Shrubland, Grassland); drop it to keep all IGBP classes. See `python3 scripts/filter_candidate_sites.py --help` for ranking/hub-priority options.

### 2. Download and convert candidate sites

```bash
fluxnet-shuttle download -f fluxnet_shuttle_snapshot_*.csv -s ES-LJu -o downloads/

Rscript scripts/install_fluxnetlsm.R   # once per machine; needs: brew install r netcdf gdal

Rscript scripts/convert_fluxnetlsm.R \
  --site=ES-LJu \
  --infile=downloads/ES-LJu/EUF_ES-LJu_FLUXNET_FLUXMET_HH_*.csv \
  --outdir=fluxnetlsm_out

ORIG_DIR=fluxnetlsm_out/Nc_files/Met OUT_DIR=forcing/shuttle-pilot20 \
  scripts/regenerate_forcing.sh
```

### 3. Plot the candidate sites

```bash
python3 scripts/plot_sites_map.py --snapshot-csv fluxnet_shuttle_snapshot_*.csv --output sites_map.png
```

### 4. Run ecLand and postprocess/benchmark

Blocked until `clim/shuttle-pilot20/surfclim_<site>.nc` / `surfinit_<site>.nc` exist for these sites (see Status above). Once they do, the remaining steps are unchanged from `plumber2-ecland`'s workflow, just pointed at a different `GROUP` and `--experiment-name`:

```bash
scripts/ecland_run_experiment.sh -g shuttle-pilot20 -t insitu -x <path_to_ecland_executable>
python3 scripts/postproc.py --experiment-name shuttle-pilot20 --overwrite
python3 scripts/benchmark.py --model-dir benchmark/models/shuttle-pilot20 \
  --out-dir benchmark/dashboards/shuttle-pilot20 --experiment-name shuttle-pilot20
```

## Requirements

- ecLand executable (built separately; see [ECMWF ecLand](https://github.com/ecmwf-ifs/ecland)), on ECMWF HPC — see [Status](#status-2026-08-17).
- Python: `numpy`, `xarray`, `netCDF4`, `pandas`, plus the [`fluxnet-shuttle`](https://github.com/fluxnet/shuttle) CLI.
- R + [FluxnetLSM](https://github.com/aukkola/FluxnetLSM) — `scripts/install_fluxnetlsm.R` installs both (needs `brew install r netcdf gdal` first on macOS).
- NCO tools (`ncrename`, `ncks`, `ncatted`, `nccopy`) for `scripts/regenerate_forcing.sh`.

## License

Scripts forked from `plumber2-ecland`: Copyright 2023– ECMWF, licensed under the [Apache Licence Version 2.0](http://www.apache.org/licenses/LICENSE-2.0). New scripts in this repo follow the same license.
