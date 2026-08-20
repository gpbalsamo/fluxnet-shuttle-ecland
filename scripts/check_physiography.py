#!/usr/bin/env python3
"""Check that a surfclim/surfinit pair actually carries usable physiography.

The create_forcing tool exits 0 for a point whose nearest model gridpoint has
no land -- a coastal, island or tidal-marsh site -- but writes both files with
every physiographic field set to NaN. Confirmed 2026-08-19 on CA-RBM (Richmond
Brackish Marsh, 49.13N 123.20W, in the Fraser delta): soil type, orography,
vegetation type and cover, and the land-sea fraction itself are all NaN, with
which_surface=land and with orig alike.

Nothing downstream would notice. The filenames are right, the dimensions are
right, and ecland_run_model.sh pairs files by name, so such a file would be
fed to the model and produce nonsense rather than an error.

Exits 0 if the files are usable, 1 with a diagnosis if not, so a caller can
treat the site as failed.

Usage:
    check_physiography.py <dir containing surfclim_*.nc / surfinit_*.nc>
"""
from __future__ import annotations

import glob
import os
import sys

import numpy as np
from netCDF4 import Dataset

# Fields that must be finite for the physiography to mean anything. Kept to
# what ecLand is actually driven by, so a site is not rejected over an
# optional extra.
SURFCLIM_REQUIRED = ("landsea", "sotype", "geopot", "tvl", "tvh", "cvl", "cvh")
SURFINIT_REQUIRED = ("SoilTemp", "SoilMoist")


def bad_fields(path: str, required: tuple[str, ...]) -> list[str]:
    bad = []
    with Dataset(path) as ds:
        for name in required:
            if name not in ds.variables:
                bad.append(f"{name} (absent)")
                continue
            values = np.asarray(ds.variables[name][:], dtype="float64")
            if values.size == 0 or not np.isfinite(values).any():
                bad.append(name)
    return bad


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = sys.argv[1]

    clim = sorted(glob.glob(os.path.join(root, "**", "surfclim_*.nc"), recursive=True))
    init = sorted(glob.glob(os.path.join(root, "**", "surfinit_*.nc"), recursive=True))
    if not clim:
        print(f"ERROR: no surfclim_*.nc under {root}", file=sys.stderr)
        return 1
    if not init:
        print(f"ERROR: no surfinit_*.nc under {root}", file=sys.stderr)
        return 1

    failed = False
    for path, required in [(p, SURFCLIM_REQUIRED) for p in clim] + \
                          [(p, SURFINIT_REQUIRED) for p in init]:
        bad = bad_fields(path, required)
        if bad:
            failed = True
            print(f"ERROR: {os.path.basename(path)} has no usable values for: "
                  f"{', '.join(bad)}", file=sys.stderr)
            print("       This is what a point with no land at its nearest gridpoint "
                  "looks like (coast, island, tidal marsh).", file=sys.stderr)
    if failed:
        return 1

    print(f"physiography OK: {os.path.basename(clim[0])}, {os.path.basename(init[0])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
