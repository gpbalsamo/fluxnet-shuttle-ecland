#!/usr/bin/env python3
"""Fill a FLUXMET CSV's missing CO2_F_MDS from NOAA GML monthly mean CO2.

Why this exists: FluxnetLSM's `missing_met` threshold defaults to 0, meaning a
year is discarded if ANY met variable still has a gap after gapfilling. CO2 is
the one met variable the Shuttle's ERA5 file cannot fill -- it has no ERA
counterpart (Essential_met=NA, ERAinterim_variable=NA in FluxnetLSM's own
Output_variables_FLUXNET2015_FULLSET.csv) -- so a tower with intermittent CO2
loses whole years over a variable ecLand is not even driven by here
(LEAIRCO2COUP=.FALSE. in namelists/). Measured 2026-08-18 across a full
775-site run: 97 sites produced no output at all, and on the one inspected in
detail (ES-MtN) every other met variable was at 0.00% missing after ERA5
gapfilling while CO2air sat at 38.3%.

Filling the gaps with the NOAA global monthly mean removes that blockage
without inventing local structure the data does not have. Filled half-hours
get CO2_F_MDS_QC=3 -- the same "poorest gapfill quality" class the FLUXNET2015
schema already uses -- so FluxnetLSM's own accounting reports them as
gap-filled and scripts/qc_classify.py bands them accordingly. Nothing is
silently upgraded to look like a measurement.

Rewrites the CSV in place (via a temporary file in the same directory). Rows
whose year predates the NOAA series (starts 1979-01) are left missing and
reported rather than extrapolated.

Usage:
    python3 scripts/fill_co2_from_noaa.py \
        --infile downloads/ES-MtN/EUF_ES-MtN_FLUXNET_FLUXMET_HH_2024-2024_v1.3_r1.csv \
        --co2-csv reference/noaa_gml_co2_monthly.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
import tempfile
from pathlib import Path

MISSING = "-9999"
# FLUXNET2015 QC convention for _F_MDS variables: 0 measured, 1/2/3 gapfilled
# in decreasing quality. A global monthly mean is the poorest class.
FILLED_QC = "3"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--infile", type=Path, required=True, help="FLUXMET HH/HR CSV to rewrite in place.")
    p.add_argument("--co2-csv", type=Path, required=True,
                   help="NOAA monthly table from scripts/fetch_noaa_co2.py.")
    p.add_argument("--co2-col", default="CO2_F_MDS", help="CO2 column name (default: CO2_F_MDS).")
    p.add_argument("--qc-col", default="CO2_F_MDS_QC", help="CO2 QC column name (default: CO2_F_MDS_QC).")
    p.add_argument("--time-col", default="TIMESTAMP_START",
                   help="Timestamp column, format YYYYMMDDHHMM (default: TIMESTAMP_START).")
    return p.parse_args()


def load_co2(path: Path) -> dict[tuple[int, int], str]:
    table = {}
    for r in csv.DictReader(open(path)):
        table[(int(r["year"]), int(r["month"]))] = r["co2_ppm"]
    if not table:
        raise SystemExit(f"ERROR: no rows in {path}")
    return table


def main() -> int:
    args = parse_args()
    if not args.infile.is_file():
        print(f"ERROR: infile not found: {args.infile}", file=sys.stderr)
        return 1
    if not args.co2_csv.is_file():
        print(f"ERROR: CO2 table not found: {args.co2_csv} "
              f"(build it with scripts/fetch_noaa_co2.py)", file=sys.stderr)
        return 1

    co2 = load_co2(args.co2_csv)

    with open(args.infile) as fh:
        header_line = fh.readline()
        if not header_line:
            print(f"ERROR: empty file: {args.infile}", file=sys.stderr)
            return 1
        header = header_line.rstrip("\n").split(",")
        try:
            i_co2 = header.index(args.co2_col)
            i_qc = header.index(args.qc_col)
            i_time = header.index(args.time_col)
        except ValueError:
            # A site with no CO2 columns at all cannot be blocked by CO2, so
            # this is a no-op rather than an error.
            print(f"{args.infile.name}: no {args.co2_col}/{args.qc_col} columns -- nothing to fill")
            return 0

        n_rows = n_filled = n_present = n_no_co2_month = 0
        # These files carry no quoted fields (verified against real ICOS/
        # AmeriFlux/TERN FLUXMET exports), so a plain split is safe here and
        # markedly faster than csv.reader over a multi-hundred-MB file.
        tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=str(args.infile.parent),
                                          prefix=".co2fill_", suffix=".csv")
        try:
            with tmp:
                tmp.write(header_line)
                for line in fh:
                    if not line.strip():
                        continue
                    n_rows += 1
                    row = line.rstrip("\n").split(",")
                    if row[i_co2] != MISSING:
                        n_present += 1
                        tmp.write(line)
                        continue
                    stamp = row[i_time]
                    key = (int(stamp[:4]), int(stamp[4:6]))
                    value = co2.get(key)
                    if value is None:
                        n_no_co2_month += 1
                        tmp.write(line)
                        continue
                    row[i_co2] = value
                    row[i_qc] = FILLED_QC
                    n_filled += 1
                    tmp.write(",".join(row) + "\n")
            os.replace(tmp.name, args.infile)
        except BaseException:
            # Never leave a half-rewritten file in place of the original.
            if os.path.exists(tmp.name):
                os.unlink(tmp.name)
            raise

    pct = (100.0 * n_filled / n_rows) if n_rows else 0.0
    print(f"{args.infile.name}: {n_rows} rows, {n_present} CO2 present, "
          f"{n_filled} filled from NOAA ({pct:.1f}%)"
          + (f", {n_no_co2_month} outside the NOAA series (left missing)" if n_no_co2_month else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
