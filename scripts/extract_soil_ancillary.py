#!/usr/bin/env python3
"""Extract ancillary soil moisture/temperature observations for Shuttle sites.

The FLUXNET FULLSET each site downloads as (SWC_F_MDS_<depth>, TS_F_MDS_<depth>,
plus _QC flags) never reaches this repo's tracked outputs: convert_fluxnetlsm.R
targets FluxnetLSM's ALMA-CF met/flux variable set, which has no soil-state
slot, so these columns are silently dropped on the way to forcing/<group>/ and
flux/<group>/. This script is a separate, minimal path straight from the same
per-site download to a small soil/<group>/soil_<site>_<Y1>-<Y2>.nc, for sites
where they exist -- see reference/soil_coverage_<group>.csv (built by this
script) for which sites that is and how complete each depth is.

Deliberately does none of what convert_fluxnetlsm.R does: no gapfilling, no
acceptance thresholds, no unit conversion. Raw values (FLUXNET2015's -9999
sentinel mapped to NaN) plus their own QC flags, so filtering is a decision
made against the output, not a rerun. Depths are index order only
(SWC_F_MDS_1, _2, ...) -- FLUXNET2015 does not put actual depth-in-cm in the
FLUXMET file itself (it's in the per-site BADM/BIF metadata, which this
script does not parse).

Reads only the FLUXMET_HH member of each site's zip, and only the columns it
needs from it (pandas usecols against a stream opened inside the zip, so the
multi-hundred-MB member is never fully materialized) -- matches this repo's
forcing/flux time resolution, so soil state lines up with model output on the
same timestep. Disk-safe like run_forcing_pipeline.sh: the zip is deleted the
moment its site is scored, whether or not that site had anything to extract.

Usage:
    python3 scripts/extract_soil_ancillary.py \\
        -f fluxnet_shuttle_snapshot_*.csv \\
        -g shuttle-all775-era5 \\
        -S reference/subset_plumber2_170.txt \\
        -j 4

Omit -S to process every site in the snapshot. Resumable: a site already
present in reference/soil_coverage_<group>.csv is skipped (delete its row, or
delete soil/<group>/soil_<site>_*.nc and the row, to force a redo).
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import shutil
import subprocess
import sys
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import pandas as pd
import xarray as xr

FLUXNET_SHUTTLE = shutil.which("fluxnet-shuttle") or "/perm/pad/venv-shuttle/bin/fluxnet-shuttle"

REPORT_FIELDS = [
    "site", "status", "hub", "resolution", "n_rows",
    "n_swc_depths", "swc_max_cov", "swc_min_cov",
    "n_ts_depths", "ts_max_cov", "ts_min_cov",
    "period", "outfile",
]

# FLUXNET2015 MDS gapfilling QC: 0 measured, 1 good gapfill (ERA-based or MDS
# with full window), 2 medium, 3 poor/long-gap fill.
QC_NOTE = ("QC flag per FLUXNET2015 convention: 0 = measured, "
           "1 = good quality gapfill, 2 = medium, 3 = poor/long-gap gapfill.")


def site_coords(site_csv: Path, site: str) -> tuple[float | None, float | None]:
    if not hasattr(site_coords, "_cache"):
        df = pd.read_csv(site_csv, usecols=["SiteCode", "SiteLatitude", "SiteLongitude"])
        site_coords._cache = df.set_index("SiteCode")
    try:
        row = site_coords._cache.loc[site]
        return float(row["SiteLatitude"]), float(row["SiteLongitude"])
    except (KeyError, ValueError, TypeError):
        return None, None


def parse_var_depths(zf: zipfile.ZipFile, resolution: str) -> dict[str, float]:
    """Column -> depth below surface in metres, from the zip's BIFVARINFO member.

    FLUXNET2015's FLUXMET file only gives depth as an index (SWC_F_MDS_1,
    _2, ... "1 is shallowest") -- the real depth lives in per-column BADM
    metadata shipped alongside it, keyed by VAR_INFO_HEIGHT: metres, positive
    above ground, so a soil sensor's is negative and depth_m = -HEIGHT.
    Confirmed present with this exact field name across ICOS, AmeriFlux (AMF)
    and TERN hubs. Returns {} (not an error) if the member or field is
    missing for a given site -- the caller falls back to index order.
    """
    candidates = [n for n in zf.namelist() if f"BIFVARINFO_{resolution}" in n]
    if not candidates:
        return {}
    try:
        with zf.open(candidates[0]) as f:
            reader = csv.DictReader(line.decode("utf-8", "replace") for line in f)
            groups: dict[str, dict[str, str]] = {}
            for row in reader:
                groups.setdefault(row["GROUP_ID"], {})[row["VARIABLE"]] = row["DATAVALUE"]
    except Exception:
        return {}

    depths: dict[str, float] = {}
    for attrs in groups.values():
        varname = attrs.get("VAR_INFO_VARNAME", "")
        height = attrs.get("VAR_INFO_HEIGHT")
        if height is None:
            continue
        if not (varname.startswith("SWC_F_MDS_") or varname.startswith("TS_F_MDS_")):
            continue
        if varname.endswith("_QC"):
            continue
        try:
            depths[varname] = -float(height)
        except ValueError:
            continue
    return depths


def extract_site(site: str, snapshot: str, workdir: Path, out_dir: Path,
                  site_csv: Path) -> dict:
    site_dir = workdir / site
    site_dir.mkdir(parents=True, exist_ok=True)
    row = {k: "" for k in REPORT_FIELDS}
    row["site"] = site
    try:
        subprocess.run(
            [FLUXNET_SHUTTLE, "download", "-f", snapshot, "-s", site,
             "-o", str(site_dir), "--quiet"],
            capture_output=True, text=True, timeout=600,
        )
        zips = glob.glob(str(site_dir / "*.zip"))
        if not zips:
            row["status"] = "NODOWNLOAD"
            return row
        zip_path = zips[0]
        row["hub"] = os.path.basename(zip_path).split("_")[0]

        with zipfile.ZipFile(zip_path) as zf:
            names = zf.namelist()
            # A handful of sites (9 of 775, per the repo's own README) publish
            # hourly rather than half-hourly -- same TIMESTAMP_START format and
            # column names, just one resolution up. Fall back rather than skip.
            hh_candidates = [n for n in names if "FLUXMET_HH" in n]
            resolution = "HH"
            if not hh_candidates:
                hh_candidates = [n for n in names if "FLUXMET_HR" in n]
                resolution = "HR"
            if not hh_candidates:
                row["status"] = "NOFLUXMET"
                return row
            hh_name = hh_candidates[0]
            row["resolution"] = resolution

            with zf.open(hh_name) as f:
                header = f.readline().decode("utf-8", "replace").strip().split(",")

            swc_val = sorted(c for c in header if c.startswith("SWC_F_MDS_") and not c.endswith("_QC"))
            ts_val = sorted(c for c in header if c.startswith("TS_F_MDS_") and not c.endswith("_QC"))
            if not swc_val and not ts_val:
                row["status"] = "NOSOIL"
                return row

            usecols = ["TIMESTAMP_START"] + swc_val + ts_val
            usecols += [c + "_QC" for c in swc_val if c + "_QC" in header]
            usecols += [c + "_QC" for c in ts_val if c + "_QC" in header]

            with zf.open(hh_name) as f:
                df = pd.read_csv(f, usecols=usecols, na_values=[-9999, -9999.0])

            var_depths = parse_var_depths(zf, resolution)

        row["n_rows"] = len(df)
        time = pd.to_datetime(df["TIMESTAMP_START"], format="%Y%m%d%H%M")
        y1, y2 = time.dt.year.min(), time.dt.year.max()
        period = f"{y1}-{y2}"
        row["period"] = period

        ds = xr.Dataset(coords={"time": time.values})
        lat, lon = site_coords(site_csv, site)

        def add_group(val_cols, prefix, units):
            covs = []
            for c in val_cols:
                depth = c.rsplit("_", 1)[-1]
                ds[f"{prefix}_{depth}"] = ("time", df[c].values.astype("float32"))
                depth_m = var_depths.get(c)
                ds[f"{prefix}_{depth}"].attrs.update(
                    long_name=f"{'Volumetric soil water content' if prefix=='SWC' else 'Soil temperature'}, "
                              f"depth index {depth} (raw {c})"
                              + (f", {depth_m:.3f} m below surface" if depth_m is not None else ""),
                    units=units,
                )
                if depth_m is not None:
                    ds[f"{prefix}_{depth}"].attrs["depth_m"] = round(depth_m, 4)
                qc_col = c + "_QC"
                if qc_col in df.columns:
                    # QC in {0,1,2,3}; NaN (no obs at all that half-hour) needs a
                    # signed type to hold a fill value distinct from those.
                    qc_vals = df[qc_col].round().astype("float32")
                    ds[f"{prefix}_{depth}_qc"] = ("time", qc_vals.values)
                    ds[f"{prefix}_{depth}_qc"].encoding["dtype"] = "int8"
                    ds[f"{prefix}_{depth}_qc"].encoding["_FillValue"] = -1
                    ds[f"{prefix}_{depth}_qc"].attrs["long_name"] = QC_NOTE
                covs.append(df[c].notna().mean())
            return covs

        swc_covs = add_group(swc_val, "SWC", "%")
        ts_covs = add_group(ts_val, "TS", "deg C")

        row["n_swc_depths"] = len(swc_val)
        if swc_covs:
            row["swc_max_cov"] = f"{max(swc_covs):.4f}"
            row["swc_min_cov"] = f"{min(swc_covs):.4f}"
        row["n_ts_depths"] = len(ts_val)
        if ts_covs:
            row["ts_max_cov"] = f"{max(ts_covs):.4f}"
            row["ts_min_cov"] = f"{min(ts_covs):.4f}"

        ds.attrs.update(
            site=site,
            hub=row["hub"],
            resolution=resolution,
            latitude=lat if lat is not None else float("nan"),
            longitude=lon if lon is not None else float("nan"),
            source_zip=os.path.basename(zip_path),
            note="Raw FLUXNET2015 ancillary soil observations, gapfilled by the tower "
                 "team's own MDS processing (not by this repo). No acceptance "
                 "threshold applied -- filter on the _qc variables yourself. "
                 f"Native time resolution: {resolution} ('HR' = hourly, 'HH' = half-hourly).",
        )

        out_dir.mkdir(parents=True, exist_ok=True)
        outfile = out_dir / f"soil_{site}_{period}.nc"
        for var in ds.data_vars:
            ds[var].encoding.setdefault("zlib", True)
            ds[var].encoding.setdefault("complevel", 4)
        ds.to_netcdf(outfile)
        row["outfile"] = str(outfile)
        row["status"] = "OK"
        return row
    except subprocess.TimeoutExpired:
        row["status"] = "TIMEOUT"
        return row
    except Exception as e:
        row["status"] = f"ERROR:{type(e).__name__}:{e}"
        return row
    finally:
        shutil.rmtree(site_dir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-f", "--snapshot", required=True, help="Shuttle snapshot CSV (from listall).")
    ap.add_argument("-g", "--group", required=True, help="Output group name, e.g. shuttle-all775-era5.")
    ap.add_argument("-S", "--sites-file", help="Optional site list; default is every site in the snapshot.")
    ap.add_argument("-c", "--site-csv", default="reference/site_metadata_merged.csv",
                     help="Site coordinate table (default: reference/site_metadata_merged.csv).")
    ap.add_argument("-o", "--out-dir", help="Default: soil/<group>/")
    ap.add_argument("-W", "--workdir", default="scripts/work/soil_extract",
                     help="Scratch dir for per-site downloads (deleted per site as it goes).")
    ap.add_argument("-j", "--workers", type=int, default=4)
    ap.add_argument("--report", help="Default: reference/soil_coverage_<group>.csv")
    args = ap.parse_args()

    out_dir = Path(args.out_dir or f"soil/{args.group}")
    report_path = Path(args.report or f"reference/soil_coverage_{args.group}.csv")
    workdir = Path(args.workdir)
    site_csv = Path(args.site_csv)

    if args.sites_file:
        with open(args.sites_file) as f:
            sites = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    else:
        snap = pd.read_csv(glob.glob(args.snapshot)[0] if "*" in args.snapshot else args.snapshot)
        site_col = "site_id" if "site_id" in snap.columns else snap.columns[0]
        sites = sorted(snap[site_col].dropna().unique().tolist())

    done = set()
    write_header = not report_path.exists()
    if not write_header:
        with open(report_path) as f:
            for r in csv.DictReader(f):
                done.add(r["site"])

    todo = [s for s in sites if s not in done]
    print(f"{len(sites)} sites total, {len(done)} already done, {len(todo)} to process", flush=True)

    workdir.mkdir(parents=True, exist_ok=True)
    snapshot_path = glob.glob(args.snapshot)[0] if "*" in args.snapshot else args.snapshot

    report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(report_path, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=REPORT_FIELDS)
        if write_header:
            writer.writeheader()
            f.flush()

        # ProcessPoolExecutor, not threads: xarray's to_netcdf() goes through
        # the netCDF4/HDF5 C library, which segfaults under concurrent writes
        # from multiple threads in one process (verified -- see PR/commit
        # notes). Separate processes each get their own library state.
        with ProcessPoolExecutor(max_workers=args.workers) as ex:
            futs = {ex.submit(extract_site, s, snapshot_path, workdir, out_dir, site_csv): s
                    for s in todo}
            n = 0
            counts = {}
            for fut in as_completed(futs):
                site = futs[fut]
                try:
                    row = fut.result()
                except Exception as e:
                    row = {k: "" for k in REPORT_FIELDS}
                    row["site"] = site
                    row["status"] = f"CRASH:{e}"
                writer.writerow(row)
                f.flush()
                n += 1
                counts[row["status"]] = counts.get(row["status"], 0) + 1
                if n % 10 == 0 or n == len(todo):
                    print(f"[{n}/{len(todo)}] {site}: {row['status']}", flush=True)

    print("Done:", counts, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
