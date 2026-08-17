#!/usr/bin/env python3
"""
Compare forcing and post-processed time ranges for every site in a group.

Expected layout
---------------
Forcing files:
    forcing/<group>/
        met_insituHT_<SITE>.nc

Post-processed files:
    postprocessed/
        ecLand_<experiment-name>_<SITE>.nc

The script prints one row per site and writes a CSV summary.

Examples
--------
    python3 check_dates.py

    python3 check_dates.py \
        --forcing-dir forcing/shuttle-pilot20 \
        --postproc-dir postprocessed --experiment-name ecland

    python3 check_dates.py --show-all-times
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import xarray as xr


DEFAULT_FORCING_DIR = Path("forcing/PLUMBER2")
DEFAULT_POSTPROC_DIR = Path("postprocessed")
DEFAULT_CSV = Path("postprocessed/date_validation.csv")
DEFAULT_EXPERIMENT_NAME = "ecland"


@dataclass
class TimeInfo:
    count: int
    start: str
    end: str
    duplicates: int
    monotonic: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare PLUMBER2 forcing and post-processed date ranges."
    )
    parser.add_argument(
        "--forcing-dir",
        type=Path,
        default=DEFAULT_FORCING_DIR,
        help=f"Forcing directory (default: {DEFAULT_FORCING_DIR})",
    )
    parser.add_argument(
        "--postproc-dir",
        type=Path,
        default=DEFAULT_POSTPROC_DIR,
        help=f"Post-processed directory (default: {DEFAULT_POSTPROC_DIR})",
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=DEFAULT_CSV,
        help=f"CSV report path (default: {DEFAULT_CSV})",
    )
    parser.add_argument(
        "--show-all-times",
        action="store_true",
        help="Also print the first and last three timestamps for mismatched sites.",
    )
    parser.add_argument(
        "--experiment-name",
        default=DEFAULT_EXPERIMENT_NAME,
        help=f"Must match --experiment-name passed to postproc.py (default: {DEFAULT_EXPERIMENT_NAME})",
    )
    return parser.parse_args()


def format_time(value: object) -> str:
    """Return a compact ISO-like timestamp for numpy/cftime datetime values."""
    try:
        return np.datetime_as_string(np.asarray(value), unit="s")
    except (TypeError, ValueError):
        return str(value)


def read_time_info(path: Path) -> tuple[TimeInfo, np.ndarray]:
    """Read and validate the time coordinate from one NetCDF file."""
    with xr.open_dataset(path) as ds:
        if "time" not in ds.coords and "time" not in ds.variables:
            raise KeyError("no time coordinate")

        values = np.asarray(ds["time"].values)

    if values.size == 0:
        raise ValueError("empty time coordinate")

    # Work with flattened station time series.
    values = values.reshape(-1)

    unique_values, counts = np.unique(values, return_counts=True)
    duplicates = int(np.sum(counts - 1))

    if values.size > 1:
        monotonic = bool(np.all(values[1:] >= values[:-1]))
    else:
        monotonic = True

    info = TimeInfo(
        count=int(values.size),
        start=format_time(values[0]),
        end=format_time(values[-1]),
        duplicates=duplicates,
        monotonic=monotonic,
    )
    return info, values


def forcing_site_name(path: Path) -> str:
    """Extract SITE from met_insituHT_<SITE>.nc."""
    prefix = "met_insituHT_"
    name = path.stem
    return name[len(prefix):] if name.startswith(prefix) else name


def postproc_site_name(path: Path, experiment_name: str) -> str:
    """Extract SITE from ecLand_<experiment_name>_<SITE>.nc."""
    prefix = f"ecLand_{experiment_name}_"
    name = path.stem
    return name[len(prefix):] if name.startswith(prefix) else name


def main() -> int:
    args = parse_args()

    forcing_dir = args.forcing_dir.expanduser().resolve()
    postproc_dir = args.postproc_dir.expanduser().resolve()
    csv_path = args.csv.expanduser().resolve()

    if not forcing_dir.is_dir():
        print(f"ERROR: forcing directory not found: {forcing_dir}", file=sys.stderr)
        return 2

    if not postproc_dir.is_dir():
        print(f"ERROR: post-processed directory not found: {postproc_dir}", file=sys.stderr)
        return 2

    forcing_files = {
        forcing_site_name(path): path
        for path in sorted(forcing_dir.glob("met_insituHT_*.nc"))
    }
    postproc_files = {
        postproc_site_name(path, args.experiment_name): path
        for path in sorted(postproc_dir.glob(f"ecLand_{args.experiment_name}_*.nc"))
    }

    all_sites = sorted(set(forcing_files) | set(postproc_files))

    if not all_sites:
        print("ERROR: no forcing or post-processed files found.", file=sys.stderr)
        return 1

    rows: list[dict[str, object]] = []
    mismatch_count = 0

    header = (
        f"{'SITE':25s} {'FORCING N':>10s} {'FORCING START':19s} "
        f"{'FORCING END':19s} {'POST N':>8s} {'POST START':19s} "
        f"{'POST END':19s} {'STATUS'}"
    )
    print(header)
    print("-" * len(header))

    for site in all_sites:
        forcing_path = forcing_files.get(site)
        postproc_path = postproc_files.get(site)

        status_parts: list[str] = []

        forcing_info = None
        forcing_times = None
        post_info = None
        post_times = None

        if forcing_path is None:
            status_parts.append("MISSING_FORCING")
        else:
            try:
                forcing_info, forcing_times = read_time_info(forcing_path)
            except Exception as exc:
                status_parts.append(f"FORCING_ERROR:{exc}")

        if postproc_path is None:
            status_parts.append("MISSING_POSTPROC")
        else:
            try:
                post_info, post_times = read_time_info(postproc_path)
            except Exception as exc:
                status_parts.append(f"POSTPROC_ERROR:{exc}")

        if forcing_info and post_info:
            if forcing_info.start != post_info.start:
                status_parts.append("START_DIFF")
            if forcing_info.end != post_info.end:
                status_parts.append("END_DIFF")
            if forcing_info.count != post_info.count:
                status_parts.append("COUNT_DIFF")
            if forcing_info.duplicates:
                status_parts.append("FORCING_DUPLICATES")
            if post_info.duplicates:
                status_parts.append("POSTPROC_DUPLICATES")
            if not forcing_info.monotonic:
                status_parts.append("FORCING_NOT_MONOTONIC")
            if not post_info.monotonic:
                status_parts.append("POSTPROC_NOT_MONOTONIC")

            # Check exact timestamp equality, not only first/last/count.
            if (
                forcing_times is not None
                and post_times is not None
                and (
                    forcing_times.shape != post_times.shape
                    or not np.array_equal(forcing_times, post_times)
                )
            ):
                status_parts.append("TIME_AXIS_DIFF")

        status = "OK" if not status_parts else ",".join(status_parts)
        if status != "OK":
            mismatch_count += 1

        print(
            f"{site:25.25s} "
            f"{forcing_info.count if forcing_info else '-':>10} "
            f"{forcing_info.start if forcing_info else '-':19.19s} "
            f"{forcing_info.end if forcing_info else '-':19.19s} "
            f"{post_info.count if post_info else '-':>8} "
            f"{post_info.start if post_info else '-':19.19s} "
            f"{post_info.end if post_info else '-':19.19s} "
            f"{status}"
        )

        if args.show_all_times and status != "OK":
            if forcing_times is not None:
                print("  forcing first:", [format_time(v) for v in forcing_times[:3]])
                print("  forcing last :", [format_time(v) for v in forcing_times[-3:]])
            if post_times is not None:
                print("  post first   :", [format_time(v) for v in post_times[:3]])
                print("  post last    :", [format_time(v) for v in post_times[-3:]])

        rows.append(
            {
                "site": site,
                "forcing_file": str(forcing_path) if forcing_path else "",
                "postproc_file": str(postproc_path) if postproc_path else "",
                "forcing_count": forcing_info.count if forcing_info else "",
                "forcing_start": forcing_info.start if forcing_info else "",
                "forcing_end": forcing_info.end if forcing_info else "",
                "postproc_count": post_info.count if post_info else "",
                "postproc_start": post_info.start if post_info else "",
                "postproc_end": post_info.end if post_info else "",
                "status": status,
            }
        )

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print()
    print(f"Sites checked : {len(all_sites)}")
    print(f"Mismatches    : {mismatch_count}")
    print(f"CSV report    : {csv_path}")

    return 1 if mismatch_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
