#!/usr/bin/env python3
"""Merge FluxnetLSM's packaged Site_metadata.csv with a Shuttle snapshot.

Why: FluxnetLSM's bundled inst/extdata/Site_metadata.csv (874 sites) predates
the FLUXNET Shuttle by years -- most Shuttle-only sites (new ICOS/TERN
additions, sites never in the original FLUXNET2015 release) aren't in it. If a
site isn't found, FluxnetLSM silently proceeds with SiteLatitude/SiteLongitude/
IGBP_vegetation_short all NA (see R/Site_metadata.R's site_metadata_template())
-- the conversion doesn't error, but the output NetCDF has no real coordinates,
which defeats the point.

This script builds a merged CSV in FluxnetLSM's exact schema: for sites already
in FluxnetLSM's table, the row is kept as-is (preserving real canopy/reference
height data where FluxnetLSM has it); for Shuttle-only sites, a new row is
added with SiteCode/SiteLatitude/SiteLongitude/IGBP_vegetation_short/long/
Fullname from the Shuttle snapshot and everything else NA (matching
FluxnetLSM's own site_metadata_template() defaults) -- correct coordinates and
biome class, not fabricated height/tier data.

Pass the output to convert_fluxnetlsm.R via --site-csv (which forwards to
FluxnetLSM's site_csv_file argument).

Usage:
    python3 scripts/build_site_metadata.py fluxnet_shuttle_snapshot_*.csv \
        --out reference/site_metadata_merged.csv
"""
from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from pathlib import Path

# IGBP short code -> long name, for the 15 classes observed across the full
# 775-site 2026-08-17 Shuttle snapshot (BSV, CRO, CSH, CVM, DBF, DNF, EBF,
# ENF, GRA, MF, OSH, SAV, SNO, WET, WSA -- no URB/WAT seen). Matches
# scripts/plot_sites_map.py's IGBP_TO_GROUP mapping.
IGBP_LONG_NAME = {
    "ENF": "Evergreen Needleleaf Forest",
    "EBF": "Evergreen Broadleaf Forest",
    "DBF": "Deciduous Broadleaf Forest",
    "MF": "Mixed Forest",
    "DNF": "Deciduous Needleleaf Forest",
    "OSH": "Open Shrubland",
    "CSH": "Closed Shrubland",
    "SAV": "Savanna",
    "WSA": "Woody Savanna",
    "GRA": "Grassland",
    "CRO": "Cropland",
    "WET": "Permanent Wetland",
    "CVM": "Cropland/Natural Vegetation Mosaic",
    "BSV": "Barren or Sparsely Vegetated",
    "SNO": "Snow and Ice",
}

# FluxnetLSM's Site_metadata.csv column schema (see site_metadata_template()
# in FluxnetLSM's R/Site_metadata.R) -- new rows must use these exact names.
SCHEMA = [
    "SiteCode", "Exclude", "Exclude_reason", "CABLE_PFT", "CABLE_patchfrac",
    "Source_CABLE_PFT", "Description", "TowerStatus", "Country", "Fullname",
    "SiteLatitude", "SiteLongitude", "SiteElevation", "IGBP_vegetation_short",
    "IGBP_vegetation_long", "Tier", "MeasurementHeight", "TowerHeight",
    "CanopyHeight", "VegetationDescription", "SoilType", "Disturbance",
    "CropDescription", "Irrigation", "Reference",
]


def default_fluxnetlsm_csv() -> Path | None:
    try:
        out = subprocess.run(
            ["Rscript", "-e",
             'cat(system.file("extdata", "Site_metadata.csv", package = "FluxnetLSM"))'],
            capture_output=True, text=True, check=True,
        )
        path = Path(out.stdout.strip())
        return path if path.is_file() else None
    except Exception:
        return None


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("snapshot_csv", type=Path, help="Shuttle listall snapshot CSV.")
    p.add_argument("--fluxnetlsm-csv", type=Path, default=None,
                   help="FluxnetLSM's packaged Site_metadata.csv (default: auto-detected via "
                        "`Rscript -e system.file(...)`, i.e. wherever FluxnetLSM is installed).")
    p.add_argument("--out", type=Path, required=True, help="Output merged CSV path.")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    fluxnetlsm_csv = args.fluxnetlsm_csv or default_fluxnetlsm_csv()
    if fluxnetlsm_csv is None or not fluxnetlsm_csv.is_file():
        print("ERROR: could not locate FluxnetLSM's packaged Site_metadata.csv -- "
              "install FluxnetLSM (scripts/install_fluxnetlsm.R) or pass --fluxnetlsm-csv.",
              file=sys.stderr)
        return 1
    if not args.snapshot_csv.is_file():
        print(f"ERROR: snapshot CSV not found: {args.snapshot_csv}", file=sys.stderr)
        return 1

    # FluxnetLSM's packaged CSV has non-UTF-8 bytes (e.g. "\xa9" in a
    # copyright-attributed Description field) -- latin-1 never raises on
    # arbitrary byte values, so it round-trips safely either way.
    base_rows = list(csv.DictReader(open(fluxnetlsm_csv, encoding="latin-1")))
    known_codes = {r["SiteCode"] for r in base_rows}
    print(f"FluxnetLSM packaged metadata: {len(base_rows)} sites")

    shuttle_rows = list(csv.DictReader(open(args.snapshot_csv)))
    # dedupe by site_id (a site can appear once per product in the snapshot)
    by_site = {r["site_id"]: r for r in shuttle_rows}
    print(f"Shuttle snapshot: {len(by_site)} unique sites")

    added = 0
    unmapped_igbp = set()
    new_rows = []
    for site_id, r in sorted(by_site.items()):
        if site_id in known_codes:
            continue
        igbp = r.get("igbp") or ""
        long_name = IGBP_LONG_NAME.get(igbp)
        if igbp and long_name is None:
            unmapped_igbp.add(igbp)
        row = {col: "" for col in SCHEMA}
        row.update({
            "SiteCode": site_id,
            "Exclude": "FALSE",
            "Fullname": r.get("site_name", ""),
            "SiteLatitude": r.get("location_lat", ""),
            "SiteLongitude": r.get("location_long", ""),
            "IGBP_vegetation_short": igbp,
            "IGBP_vegetation_long": long_name or "",
        })
        new_rows.append(row)
        added += 1

    if unmapped_igbp:
        print(f"WARNING: no long name mapped for IGBP code(s) {sorted(unmapped_igbp)} "
              f"-- add to IGBP_LONG_NAME in this script.", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=SCHEMA)
        w.writeheader()
        for r in base_rows:
            w.writerow({col: r.get(col, "") for col in SCHEMA})
        for r in new_rows:
            w.writerow(r)

    print(f"Added {added} Shuttle-only sites -> {len(base_rows) + added} total rows")
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
