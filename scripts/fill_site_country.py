#!/usr/bin/env python3
"""Derive each site's country from its coordinates, for the sites that have none.

WHY. `benchmark.py` reads the country from the `country` global attribute of the
observed flux file, which FluxnetLSM copies from its bundled `Site_metadata.csv`.
That table covers ~874 mostly pre-2017 FLUXNET2015 sites, so of the 775 FLUXNET
Shuttle sites only the 300 inside it carry a country; the other 475 -- the newer
Shuttle-discovered towers -- have an empty attribute, and show up unlabelled in
the dashboard. They are the same 475 that carry no `elevation`, for the same
reason. `reference/site_metadata_merged.csv` cannot close the gap either: the
Shuttle snapshot it merges in supplies no country of its own.

The coordinates can, and they are present for all 775. This resolves each site
against Natural Earth's 10 m admin-0 country boundaries and writes a lookup that
`benchmark.py` falls back to when the attribute is empty.

COASTAL SITES. Flux towers sit on coasts, in estuaries and on small islands, and
a 10 m coastline will place some of them just offshore. A point that lands in no
polygon is therefore matched to the nearest country within `--tolerance-km`
(default 25) rather than dropped; the CSV records which sites needed that, so a
questionable match can be checked rather than silently trusted.

The derived value is written for every site, including those that already have a
declared one, so the two can be compared -- `--report` prints the disagreements.
Only sites with no declared country are filled by `benchmark.py`; the declared
value always wins, even where it is inconsistently formatted (many read
"Arizona, United States" rather than "United States").

Usage:
  python3 scripts/fill_site_country.py --flux-dir flux/<group> [--out reference/site_country.csv]
  python3 scripts/fill_site_country.py --flux-dir flux/<group> --report

(C) Copyright 2026- ECMWF.

Licensed under the Apache Licence Version 2.0:
http://www.apache.org/licenses/LICENSE-2.0

In applying this licence, ECMWF does not waive the privileges and immunities
granted to it by virtue of its status as an intergovernmental organisation,
nor does it submit to any jurisdiction.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

import netCDF4
import numpy as np

DEFAULT_OUT = Path('reference/site_country.csv')
NA_VALUES = {'', 'NA', 'N/A', 'NAN', 'NONE', 'UNKNOWN'}

# Natural Earth's formal names, mapped to the short forms the declared countries
# already use, so a filled value cannot read as a different country from a
# declared one. Only the names that actually differ are listed; everything else
# NE returns (Japan, Canada, Spain, ...) already matches.
NAME_ALIASES = {
    'United States of America': 'United States',
    "People's Republic of China": 'China',
    'Republic of Korea': 'South Korea',
    'Russian Federation': 'Russia',
    'Czechia': 'Czech Republic',
    'United Republic of Tanzania': 'Tanzania',
    'Republic of Serbia': 'Serbia',
    'Kingdom of the Netherlands': 'Netherlands',
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--flux-dir', type=Path, required=True,
                   help='Directory of observed flux NetCDF files (one per site).')
    p.add_argument('--out', type=Path, default=DEFAULT_OUT,
                   help=f'Lookup CSV to write (default: {DEFAULT_OUT}).')
    p.add_argument('--tolerance-km', type=float, default=25.0,
                   help='Max distance to the nearest country for an offshore point '
                        '(default: 25).')
    p.add_argument('--report', action='store_true',
                   help='Print coverage and any declared/derived disagreements.')
    return p.parse_args()


def load_countries():
    """Natural Earth 10 m admin-0 boundaries as (name, iso_a2, geometry)."""
    import cartopy.io.shapereader as shpreader
    path = shpreader.natural_earth(resolution='10m', category='cultural',
                                   name='admin_0_countries')
    out = []
    for rec in shpreader.Reader(path).records():
        a = rec.attributes
        # NAME is the common short form ("United States of America" is ADMIN);
        # prefer the form that matches how the declared values are written.
        name = (a.get('NAME_EN') or a.get('NAME') or a.get('ADMIN') or '').strip()
        iso = (a.get('ISO_A2') or '').strip()
        if name:
            out.append((name, iso, rec.geometry))
    return out


def site_records(flux_dir: Path):
    """(site, period, lat, lon, declared_country) for each flux file."""
    for f in sorted(flux_dir.glob('*.nc')):
        m = re.match(r'([A-Za-z0-9\-]+)_(\d{4}-\d{4})_', f.name)
        if not m:
            continue
        with netCDF4.Dataset(f) as d:
            lat = float(np.asarray(d.variables['latitude'][:]).squeeze())
            lon = float(np.asarray(d.variables['longitude'][:]).squeeze())
            declared = (getattr(d, 'country', '') or '').strip()
        if declared.upper() in NA_VALUES:
            declared = ''
        yield m.group(1), m.group(2), lat, lon, declared


def resolve(lon: float, lat: float, countries, tol_deg: float):
    """Country containing the point, else the nearest within tol_deg.

    Also returns the distance to the nearest *other* country, which is how close
    the site sits to a border. A tower a few hundred metres inside one is a
    coin-flip against a 10 m coastline: DE-Lkb (49.0996, 13.3047) is declared in
    Germany and lands in the Czech Republic here. Sites with a small margin are
    flagged in the CSV so a filled value near a border can be checked.
    """
    from shapely.geometry import Point
    pt = Point(lon, lat)
    inside, best, best_d = None, None, float('inf')
    for name, iso, geom in countries:
        if inside is None and geom.contains(pt):
            inside = (name, iso)
            continue
        # Cheap bounding-box reject before the real distance computation.
        x0, y0, x1, y1 = geom.bounds
        if (x0 - 2.0) > lon or lon > (x1 + 2.0) or (y0 - 2.0) > lat or lat > (y1 + 2.0):
            continue
        d = geom.distance(pt)
        if d < best_d:
            best, best_d = (name, iso), d
    if inside is not None:
        return inside[0], inside[1], 0.0, best_d
    if best is not None and best_d <= tol_deg:
        return best[0], best[1], best_d, float('inf')
    return '', '', best_d, float('inf')


def main() -> int:
    args = parse_args()
    if not args.flux_dir.is_dir():
        print(f'ERROR: no such directory: {args.flux_dir}', file=sys.stderr)
        return 2
    countries = load_countries()
    # Degrees, not km: a crude but conservative conversion at the equator, so the
    # tolerance is never larger than intended at higher latitudes.
    tol_deg = args.tolerance_km / 111.0

    rows, n_offshore, n_unresolved, n_border = [], 0, 0, 0
    for site, period, lat, lon, declared in site_records(args.flux_dir):
        name, iso, dist, border = resolve(lon, lat, countries, tol_deg)
        name = NAME_ALIASES.get(name, name)
        if not name:
            n_unresolved += 1
        elif dist > 0:
            n_offshore += 1
        border_km = border * 111.0 if border != float('inf') else float('inf')
        if not declared and name and border_km < 5.0:
            n_border += 1
        rows.append({
            'site': site, 'period': period,
            'lat': f'{lat:.5f}', 'lon': f'{lon:.5f}',
            'country': declared or name,
            'source': 'declared' if declared else ('derived' if name else 'unresolved'),
            'declared_country': declared,
            'derived_country': name,
            'derived_iso_a2': iso,
            'offshore_km': f'{dist * 111.0:.1f}' if dist > 0 else '0.0',
            # Only near-border distances are meaningful: the bounding-box reject
            # in resolve() means a large value is whatever survived the filter,
            # not a true minimum over every country. The column exists to flag
            # sites close enough to a border for the country to be in doubt.
            'border_km': f'{border_km:.1f}' if border_km <= 100.0 else '',
        })

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('w', newline='') as fh:
        # csv defaults to \r\n; the rest of reference/ is LF.
        w = csv.DictWriter(fh, fieldnames=list(rows[0]), lineterminator='\n')
        w.writeheader()
        w.writerows(rows)

    n_declared = sum(1 for r in rows if r['source'] == 'declared')
    n_derived = sum(1 for r in rows if r['source'] == 'derived')
    print(f'{len(rows)} sites -> {args.out}')
    print(f'  declared   : {n_declared}')
    print(f'  derived    : {n_derived}  ({n_offshore} matched to the nearest coast)')
    print(f'  unresolved : {n_unresolved}')
    if n_border:
        print(f'  within 5 km of a border (worth checking): {n_border}')
        for r in rows:
            if r['source'] == 'derived' and r['border_km'] and float(r['border_km']) < 5.0:
                print(f"    {r['site']:10s} {r['derived_country']:20s} "
                      f"{r['border_km']} km from the nearest other country")

    if args.report:
        # Declared values are often "State, Country"; compare the country part.
        def tail(s):
            return s.split(',')[-1].strip().lower()
        dis = [r for r in rows if r['declared_country'] and r['derived_country']
               and tail(r['declared_country']) != r['derived_country'].strip().lower()]
        print(f'\nvalidation against {n_declared} declared countries: '
              f'{n_declared - len(dis)} agree, {len(dis)} differ')
        for r in dis:
            print(f"  {r['site']:10s} declared={r['declared_country']:28s} "
                  f"derived={r['derived_country']} ({r['lat']}, {r['lon']})")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
