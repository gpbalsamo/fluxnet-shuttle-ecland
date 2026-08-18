#!/usr/bin/env python3
"""Fetch NOAA GML globally averaged marine surface monthly mean CO2.

Written to reference/noaa_gml_co2_monthly.csv as year,month,co2_ppm, for
scripts/fill_co2_from_noaa.py to use as a CO2 fallback where a flux tower has
no CO2 measurement of its own.

Why a global mean rather than a nearby station: CO2air is not a driving
variable for the ecLand configurations here (namelists set
LEAIRCO2COUP=.FALSE., so atmospheric CO2 is not coupled to photosynthesis; CO2
appears only as model output via LWRCO2). The value only has to be
physically sensible and correctly labelled, and the marine-surface global mean
is the standard, well-documented choice for exactly that. Anything more
elaborate would imply a precision the use case does not have.

Source: https://gml.noaa.gov/ccgg/trends/gl_data.html
Series starts 1979-01; earlier tower years cannot be filled from it (see
fill_co2_from_noaa.py, which reports them rather than extrapolating).

Usage:
    python3 scripts/fetch_noaa_co2.py --out reference/noaa_gml_co2_monthly.csv
"""
from __future__ import annotations

import argparse
import csv
import sys
import urllib.request
from pathlib import Path

URL = "https://gml.noaa.gov/webdata/ccgg/trends/co2/co2_mm_gl.txt"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=URL, help=f"Source URL (default: {URL})")
    p.add_argument("--out", type=Path, required=True, help="Output CSV path.")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    try:
        with urllib.request.urlopen(args.url, timeout=120) as fh:
            text = fh.read().decode("utf-8")
    except Exception as exc:
        print(f"ERROR: could not fetch {args.url}: {exc}", file=sys.stderr)
        return 1

    # Whitespace-separated columns: year month decimal average average_unc
    # trend trend_unc. "average" is the monthly mean we want; NOAA uses -99.99
    # for absent months.
    rows = []
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        year, month, _dec, average = parts[0], parts[1], parts[2], parts[3]
        if float(average) < 0:
            continue
        rows.append({"year": int(year), "month": int(month), "co2_ppm": float(average)})

    if not rows:
        print("ERROR: no usable rows parsed -- has the NOAA file format changed?", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["year", "month", "co2_ppm"])
        w.writeheader()
        w.writerows(rows)

    first, last = rows[0], rows[-1]
    print(f"Wrote {args.out}: {len(rows)} months, "
          f"{first['year']}-{first['month']:02d} ({first['co2_ppm']} ppm) to "
          f"{last['year']}-{last['month']:02d} ({last['co2_ppm']} ppm)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
