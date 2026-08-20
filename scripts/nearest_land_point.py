#!/usr/bin/env python3
"""Find the nearest land gridpoint to a site, in the model's own land-sea mask.

Why: create_forcing takes the physiography at the gridpoint nearest the
requested coordinate. For a site whose nearest gridpoint is water -- a tidal
marsh, an Arctic coastal tundra site, a tower on a lake shore -- there is no
soil, vegetation or orography to take, and the tool writes NaN for every field
while still exiting 0. 17 of the 775 FLUXNET Shuttle sites are in that
position even at O1280 (~9 km).

Those sites are not unusable; their nearest LAND gridpoint is typically a few
km away. This script finds it, so the physiography can be extracted there
instead. The tower keeps its own coordinates for everything else -- the forcing
is the tower's own measurements, and the site is still the site. Only the
static fields are borrowed, and the distance they are borrowed over is reported
so it can be recorded and judged.

Reads the land-sea mask straight from the climate directory create_forcing
itself copies from, so the mask is by construction the one the extraction will
use.

Note this necessarily moves surfinit too: both files come out of a single
extraction at one coordinate, and a sea gridpoint has no soil state to
initialise from either.

Usage:
    nearest_land_point.py --lat 71.32 --lon -156.62
    nearest_land_point.py --sites-csv noland.csv --out nudge.csv
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import numpy as np

DEFAULT_LSM = "/home/rdx/data/climate/climate.v021/1279_4/lsmoro"
LAND_THRESHOLD = 0.5
EARTH_RADIUS_KM = 6371.0088


def load_mask(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return (lats, lons, lsm) for the lsm field in a climate-directory file."""
    import eccodes

    with open(path, "rb") as fh:
        while True:
            gid = eccodes.codes_grib_new_from_file(fh)
            if gid is None:
                raise SystemExit(f"ERROR: no lsm field found in {path}")
            try:
                if eccodes.codes_get(gid, "shortName") == "lsm":
                    lats = eccodes.codes_get_array(gid, "latitudes")
                    lons = eccodes.codes_get_array(gid, "longitudes")
                    vals = eccodes.codes_get_array(gid, "values")
                    return np.asarray(lats), np.asarray(lons), np.asarray(vals)
            finally:
                eccodes.codes_release(gid)


def great_circle_km(lat1, lon1, lat2, lon2):
    """Haversine distance. Needed rather than a plain lat/lon metric because
    these sites are mostly at high latitude, where a degree of longitude is a
    small fraction of a degree of latitude."""
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp = p2 - p1
    dl = np.radians(lon2 - lon1)
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * np.arcsin(np.sqrt(a))


def nearest_land(lat: float, lon: float, lats, lons, lsm, search_deg: float = 3.0):
    """Nearest gridpoint with lsm >= threshold, and its distance in km."""
    lon360 = lon % 360.0
    # Restrict to a box first: 6.6M points is cheap to filter and expensive to
    # run haversine over repeatedly. The box grows if it holds no land.
    for half in (search_deg, 2 * search_deg, 4 * search_deg):
        dlon = np.abs(((lons - lon360 + 180.0) % 360.0) - 180.0)
        box = (np.abs(lats - lat) <= half) & (dlon <= half / max(np.cos(np.radians(lat)), 0.05))
        sel = box & (lsm >= LAND_THRESHOLD)
        if sel.any():
            idx = np.flatnonzero(sel)
            d = great_circle_km(lat, lon360, lats[idx], lons[idx])
            j = idx[int(np.argmin(d))]
            out_lon = lons[j]
            if out_lon > 180.0:
                out_lon -= 360.0
            return float(lats[j]), float(out_lon), float(d.min())
    return None


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lsm", type=Path, default=Path(DEFAULT_LSM),
                   help=f"GRIB file holding the lsm field (default: {DEFAULT_LSM})")
    p.add_argument("--lat", type=float, help="Site latitude (single-site mode).")
    p.add_argument("--lon", type=float, help="Site longitude (single-site mode).")
    p.add_argument("--sites-csv", type=Path, default=None,
                   help="CSV with site,lat,lon columns (batch mode).")
    p.add_argument("--out", type=Path, default=None,
                   help="Write site,lat,lon,orig_lat,orig_lon,offset_km here (batch mode).")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if not args.lsm.is_file():
        print(f"ERROR: land-sea mask not readable: {args.lsm}", file=sys.stderr)
        return 1

    lats, lons, lsm = load_mask(args.lsm)
    print(f"# mask: {args.lsm} ({lsm.size} points, {int((lsm >= LAND_THRESHOLD).sum())} land)",
          file=sys.stderr)

    if args.sites_csv:
        rows = list(csv.DictReader(open(args.sites_csv)))
        out_rows = []
        for r in rows:
            site = r["site"]
            lat, lon = float(r["lat"]), float(r["lon"])
            hit = nearest_land(lat, lon, lats, lons, lsm)
            if hit is None:
                print(f"{site}: NO LAND within the widest search box -- skipped", file=sys.stderr)
                continue
            nlat, nlon, dist = hit
            out_rows.append({"site": site, "lat": f"{nlat:.6f}", "lon": f"{nlon:.6f}",
                             "orig_lat": f"{lat:.6f}", "orig_lon": f"{lon:.6f}",
                             "offset_km": f"{dist:.2f}"})
            print(f"{site:9} {lat:9.4f} {lon:10.4f}  ->  {nlat:9.4f} {nlon:10.4f}   {dist:6.2f} km")
        if args.out:
            with open(args.out, "w", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=["site", "lat", "lon", "orig_lat", "orig_lon", "offset_km"])
                w.writeheader()
                w.writerows(out_rows)
            print(f"\nWrote {args.out} ({len(out_rows)} sites)")
        return 0

    if args.lat is None or args.lon is None:
        print("ERROR: give --lat/--lon, or --sites-csv", file=sys.stderr)
        return 2
    hit = nearest_land(args.lat, args.lon, lats, lons, lsm)
    if hit is None:
        print("ERROR: no land found within the widest search box", file=sys.stderr)
        return 1
    nlat, nlon, dist = hit
    print(f"{nlat:.6f} {nlon:.6f} {dist:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
