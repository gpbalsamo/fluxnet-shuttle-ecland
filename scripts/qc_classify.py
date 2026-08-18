#!/usr/bin/env python3
"""Classify forcing NetCDF files by real per-variable gap-fill intensity.

FluxnetLSM writes honest per-variable Missing_%/Gap-filled_%/Gapfilling_method
attributes into every file it produces, regardless of which acceptance preset
(scripts/convert_fluxnetlsm.R --preset) let that period through -- these
survive unchanged through scripts/regenerate_forcing.sh into the final
forcing/<group>/*.nc files. This script reads those attributes directly and
buckets each (file, variable) into the same mild/medium/heavy/complete bands
as the acceptance presets, so a period admitted under a permissive preset
(e.g. "complete") can still be told apart from one that's mostly real
observations -- no rerun needed to change how you filter/trust the data.

Usage:
    python3 scripts/qc_classify.py forcing/shuttle-all775-era5 --out qc_report.csv
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

from netCDF4 import Dataset

# Matches the acceptance-threshold ladder in convert_fluxnetlsm.R's PRESETS
# (upper bound of Gap-filled_% for each band).
BANDS = [("mild", 10), ("medium", 25), ("heavy", 50), ("complete", 100)]

MET_VARS = ("Tair", "SWdown", "LWdown", "VPD", "Psurf", "Precip", "Wind", "Qair", "RH", "CO2air")


def classify(gapfilled_pct: float) -> str:
    for name, upper in BANDS:
        if gapfilled_pct <= upper:
            return name
    return "complete"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("forcing_dir", type=Path, help="Directory of met_insituHT_<site>_<years>.nc files.")
    p.add_argument("--out", type=Path, default=None, help="Write per-(file,variable) CSV report here.")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if not args.forcing_dir.is_dir():
        print(f"ERROR: not a directory: {args.forcing_dir}", file=sys.stderr)
        return 1

    files = sorted(args.forcing_dir.glob("*.nc"))
    if not files:
        print(f"ERROR: no .nc files found in {args.forcing_dir}", file=sys.stderr)
        return 1

    rows = []
    for f in files:
        with Dataset(f) as ds:
            for var in MET_VARS:
                if var not in ds.variables:
                    continue
                v = ds.variables[var]
                gapfilled = float(getattr(v, "Gap-filled_%", 0.0))
                missing = float(getattr(v, "Missing_%", 0.0))
                method = getattr(v, "Gapfilling_method", "observed")
                rows.append({
                    "file": f.name,
                    "variable": var,
                    "missing_pct": missing,
                    "gapfilled_pct": gapfilled,
                    "gapfilling_method": method,
                    "tier": classify(gapfilled),
                })

    tier_counts: dict[str, int] = {name: 0 for name, _ in BANDS}
    for r in rows:
        tier_counts[r["tier"]] += 1
    print(f"{len(files)} files, {len(rows)} (file, variable) records")
    for name, _ in BANDS:
        print(f"  {name:9}: {tier_counts[name]}")

    if args.out:
        with open(args.out, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=["file", "variable", "missing_pct", "gapfilled_pct",
                                                "gapfilling_method", "tier"])
            w.writeheader()
            w.writerows(rows)
        print(f"Wrote {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
