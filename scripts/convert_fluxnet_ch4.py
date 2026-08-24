#!/usr/bin/env python3
"""Convert FLUXNET-CH4 Community Product CSVs to the FLUXNET2015 NetCDF schema.

FluxnetLSM cannot do this job: its variable table targets the ALMA/FLUXNET2015
met and flux set, which has no methane flux at all, so the `fluxnet-ch4` group
needs its own converter. The output is byte-compatible with what
`convert_fluxnetlsm.R` produces for the other groups -- same dims, same
`<var>`/`<var>_qc` pairing, same time-axis convention -- so `benchmark.py` reads
it with no special-casing.

Input is the half-hourly (HH) or hourly (HR) per-site CSV from
https://fluxnet.org/data/fluxnet-ch4-community-product/ (Delwiche et al. 2021,
ESSD, doi:10.5194/essd-13-3607-2021). Variable names follow that product's
published table: `TIMESTAMP_START`/`TIMESTAMP_END` (YYYYMMDDHHMM), `FCH4` in
nmolCH4 m-2 s-1 as the measured turbulent flux, `FCH4_F_ANNOPTLM` as the
neural-net gap-filled version, `LE`/`H`/`NEE` for the other fluxes, and -9999
for every missing value.

QC convention
-------------
FLUXNET-CH4's own `_QC` is not FLUXNET2015's. It flags gap *length* on the
gap-filled series (1 = gap under two months, 3 = over), and says nothing about
which half-hours were measured. `benchmark.py` scores `qc == 0` only, meaning
measured, so this script rebuilds the flag on FLUXNET2015 semantics instead:

    0  the raw (ungapfilled) variable has a value here -- measured
    1  raw is missing, filled from `_F_ANNOPTLM` with its QC = 1 (short gap)
    3  raw is missing, filled from `_F_ANNOPTLM` with its QC = 3 (long gap)
    2  raw is missing, filled, but no gap-length flag was available

So the default benchmark run scores measured methane only, exactly as it already
does for Qle, Qh and NEE, and the gap-filled values remain in the file for anyone
who wants them.

Usage
-----
    scripts/convert_fluxnet_ch4.py --from-dir <dir-of-CSVs> [--outdir flux/fluxnet-ch4]
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import xarray as xr

MISSING = -9999.0
DEFAULT_OUTDIR = Path('flux/fluxnet-ch4')
# Metadata sources, richest first. site_metadata_merged.csv is FluxnetLSM's own
# table plus the Shuttle snapshot (1349 sites); fluxnet_ch4_sites.csv is what
# fetch_fluxnet_ch4.py discovers and covers the AmeriFlux members of the pool.
DEFAULT_METADATA = (Path('reference/site_metadata_merged.csv'),
                    Path('reference/fluxnet_ch4_sites.csv'))

# FLUXNET-CH4 name -> (our name, units, long_name, CF standard_name)
VARIABLES = {
    'FCH4': ('FCH4', 'nmol/m2/s', 'Methane turbulent flux, positive upward',
             'surface_upward_mole_flux_of_methane'),
    'LE': ('Qle', 'W/m2', 'Latent heat flux from surface',
           'surface_upward_latent_heat_flux'),
    'H': ('Qh', 'W/m2', 'Sensible heat flux from surface',
          'surface_upward_sensible_heat_flux'),
    'NEE': ('NEE', 'umol/m2/s', 'Net ecosystem exchange of CO2',
            'surface_net_downward_mass_flux_of_carbon_dioxide_expressed_as_carbon'),
}
# The gap-filled counterpart, tried in order; the first present is used.
FILLED_SUFFIXES = ('_F_ANNOPTLM', '_F')
QC_SUFFIXES = ('_F_ANNOPTLM_QC', '_F_QC', '_QC')

QC_DESCRIPTION = ('Measured: 0, gap-filled with gap under two months: 1, '
                  'gap-filled with gap length unknown: 2, gap-filled with gap '
                  'over two months: 3. Rebuilt on FLUXNET2015 semantics from '
                  "FLUXNET-CH4's raw/gap-filled variable pair; the product's own "
                  '_QC flags gap length, not measurement.')

# FLX_US-Los_FLUXNET-CH4_HH_2014-2018_1-1.csv, and looser variants -- take the
# first token that looks like a site code.
SITE_RE = re.compile(r'([A-Z]{2}-[A-Za-z0-9]{3})')


def load_metadata(paths: tuple[Path, ...]) -> dict[str, dict]:
    """Merge the metadata tables into one site -> fields lookup."""
    out: dict[str, dict] = {}
    for path in paths:
        if not path.is_file():
            continue
        with path.open() as fh:
            for row in csv.DictReader(fh):
                site = (row.get('SiteCode') or row.get('site') or '').strip()
                if not site:
                    continue
                rec = out.setdefault(site, {})
                pick = {
                    'site_name': row.get('Fullname') or row.get('site_name'),
                    'lat': row.get('SiteLatitude') or row.get('lat'),
                    'lon': row.get('SiteLongitude') or row.get('lon'),
                    'elevation': row.get('SiteElevation') or row.get('elevation'),
                    'igbp': row.get('IGBP_vegetation_short') or row.get('igbp'),
                    'igbp_long': row.get('IGBP_vegetation_long'),
                    'country': row.get('Country') or row.get('country'),
                    'tower_height': row.get('TowerHeight') or row.get('MeasurementHeight'),
                }
                for k, v in pick.items():
                    if v not in (None, '', 'NA') and not rec.get(k):
                        rec[k] = v
    return out


def as_float(value, default=np.nan) -> float:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return default
    return default if f == MISSING else f


def read_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, na_values=[str(int(MISSING)), MISSING], low_memory=False)
    if 'TIMESTAMP_START' not in df.columns:
        raise ValueError(f'{path.name}: no TIMESTAMP_START column -- is this a '
                         f'FLUXNET-CH4 half-hourly/hourly file?')
    df['time'] = pd.to_datetime(df['TIMESTAMP_START'].astype('Int64').astype(str),
                                format='%Y%m%d%H%M')
    return df.sort_values('time').reset_index(drop=True)


def build_qc(df: pd.DataFrame, name: str) -> tuple[np.ndarray, np.ndarray, str]:
    """Return (values, qc, note) for one variable on FLUXNET2015 QC semantics."""
    raw = df[name].to_numpy(dtype='float64') if name in df.columns else None
    filled_col = next((name + s for s in FILLED_SUFFIXES if name + s in df.columns), None)
    qc_col = next((name + s for s in QC_SUFFIXES if name + s in df.columns), None)

    if raw is None and filled_col is None:
        raise KeyError(name)
    n = len(df)
    values = np.full(n, np.nan) if raw is None else raw.copy()
    qc = np.where(np.isfinite(values), 0.0, np.nan)

    if filled_col is not None:
        filled = df[filled_col].to_numpy(dtype='float64')
        gap = ~np.isfinite(values) & np.isfinite(filled)
        values[gap] = filled[gap]
        if qc_col is not None:
            flag = df[qc_col].to_numpy(dtype='float64')
            # The product's flag is 1 (short gap) or 3 (long gap); anything else
            # becomes 2, "filled, gap length unknown".
            mapped = np.where(flag == 1, 1.0, np.where(flag == 3, 3.0, 2.0))
            qc[gap] = mapped[gap]
        else:
            qc[gap] = 2.0
    note = (f'raw={name}'
            + (f', filled={filled_col}' if filled_col else ', not gap-filled')
            + (f', gap-flag={qc_col}' if qc_col else ''))
    return values, qc, note


def regular_axis(df: pd.DataFrame) -> tuple[pd.DatetimeIndex, int]:
    """Reindex onto a strictly regular axis, so gaps are NaN rather than absent."""
    t = pd.DatetimeIndex(df['time'])
    steps = np.diff(t.asi8) // 1_000_000_000
    step = int(np.median(steps)) if steps.size else 1800
    if step not in (1800, 3600):
        print(f'  warning: unexpected timestep {step}s, using it anyway')
    full = pd.date_range(t[0], t[-1], freq=pd.Timedelta(seconds=step))
    return full, step


def convert(path: Path, meta: dict[str, dict], outdir: Path,
            overwrite: bool) -> Path | None:
    m = SITE_RE.search(path.name)
    if not m:
        print(f'  {path.name}: no site code in filename, skipped')
        return None
    site = m.group(1)
    df = read_csv(path)
    full, step = regular_axis(df)
    df = df.set_index('time').reindex(full)
    df.index.name = 'time'
    df = df.reset_index()

    info = meta.get(site, {})
    lat, lon = as_float(info.get('lat')), as_float(info.get('lon'))
    if not (np.isfinite(lat) and np.isfinite(lon)):
        print(f'  {site}: no coordinates in the metadata tables, skipped '
              f'(benchmark.py requires latitude/longitude)')
        return None

    y1, y2 = full[0].year, full[-1].year
    out_path = outdir / f'{site}_{y1}-{y2}_FLUXNET2015_Flux.nc'
    if out_path.exists() and not overwrite:
        print(f'  {site}: {out_path.name} exists, skipped (use --overwrite)')
        return out_path

    n = len(full)
    data_vars: dict[str, xr.DataArray] = {}
    notes = []
    for src, (dst, units, long_name, std_name) in VARIABLES.items():
        try:
            values, qc, note = build_qc(df, src)
        except KeyError:
            notes.append(f'{dst}: absent')
            continue
        measured = int(np.sum(qc == 0))
        notes.append(f'{dst}: {measured}/{n} measured ({note})')
        shaped = values.reshape(n, 1, 1).astype('float32')
        data_vars[dst] = xr.DataArray(
            shaped, dims=('time', 'y', 'x'),
            attrs={'units': units, 'long_name': long_name,
                   'standard_name': std_name, 'Fluxnet_name': src,
                   'Missing_%': round(100.0 * np.sum(~np.isfinite(values)) / n, 1)})
        data_vars[f'{dst}_qc'] = xr.DataArray(
            qc.reshape(n, 1, 1).astype('float32'), dims=('time', 'y', 'x'),
            attrs={'units': '-', 'long_name': f'{dst} quality control flag',
                   'standard_name': 'NULL'})
    if 'FCH4' not in data_vars:
        print(f'  {site}: no FCH4 column, skipped')
        return None

    one = lambda v, u, ln, **kw: xr.DataArray(
        np.array([[v]], dtype='float32'), dims=('y', 'x'),
        attrs={'units': u, 'long_name': ln, **kw})
    data_vars['latitude'] = one(lat, 'degrees_north', 'Latitude',
                                standard_name='latitude')
    data_vars['longitude'] = one(lon, 'degrees_east', 'Longitude',
                                 standard_name='longitude')
    elev = as_float(info.get('elevation'))
    if np.isfinite(elev):
        data_vars['elevation'] = one(elev, 'm', 'Elevation')
    height = as_float(info.get('tower_height'))
    if np.isfinite(height):
        data_vars['reference_height'] = one(height, 'm',
                                            'Reference height of flux tower',
                                            Source='tower height')
    for name, value in (('IGBP_veg_short', info.get('igbp') or 'UNK'),
                        ('IGBP_veg_long', info.get('igbp_long') or 'Unknown')):
        data_vars[name] = xr.DataArray(
            np.array(str(value), dtype='S200'),
            attrs={'units': '-', 'long_name': name.replace('_', ' ')})

    ds = xr.Dataset(data_vars, coords={
        'time': full, 'y': np.array([1.0], 'float32'), 'x': np.array([1.0], 'float32')})
    ds.attrs = {
        'Production_time': str(pd.Timestamp.now()),
        'Production_source': 'scripts/convert_fluxnet_ch4.py',
        'site_code': site,
        'site_name': info.get('site_name', site),
        'country': info.get('country', ''),
        'Fluxnet_dataset_version': 'FLUXNET-CH4 Community Product v1.0',
        'Fluxnet_dataset_doi': '10.5194/essd-13-3607-2021',
        'Source_file': path.name,
        'Timestep_seconds': step,
        'QC_flag_descriptions': QC_DESCRIPTION,
    }
    encoding = {v: {'zlib': True, 'complevel': 4} for v in ds.data_vars
                if ds[v].dtype != object and ds[v].ndim == 3}
    encoding['time'] = {'units': f'seconds since {full[0]:%Y-%m-%d %H:%M:%S}',
                        'calendar': 'standard'}
    ds['time'].attrs = {'long_name': 'time',
                        'info': 'Time stamp indicates start time'}
    outdir.mkdir(parents=True, exist_ok=True)
    ds.to_netcdf(out_path, encoding=encoding)
    print(f'  {site} {y1}-{y2} ({step}s, {n} steps) -> {out_path.name}')
    for note in notes:
        print(f'      {note}')
    return out_path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--from-dir', type=Path, required=True,
                   help='Directory of FLUXNET-CH4 per-site HH/HR CSV files.')
    p.add_argument('--outdir', type=Path, default=DEFAULT_OUTDIR,
                   help=f'Output flux group directory (default: {DEFAULT_OUTDIR}).')
    p.add_argument('--metadata-csv', type=Path, action='append', default=None,
                   help='Site metadata table(s) supplying coordinates, IGBP and '
                        f'tower height. Default: {" then ".join(map(str, DEFAULT_METADATA))}.')
    p.add_argument('--site', action='append', default=None,
                   help='Only convert these sites; repeatable.')
    p.add_argument('--overwrite', action='store_true')
    return p.parse_args()


def main() -> int:
    args = parse_args()
    meta = load_metadata(tuple(args.metadata_csv) if args.metadata_csv
                         else DEFAULT_METADATA)
    print(f'Metadata for {len(meta)} sites')
    files = sorted(p for p in args.from_dir.glob('*.csv')
                   if 'HH' in p.name or 'HR' in p.name or 'FLUXNET-CH4' in p.name)
    if not files:
        files = sorted(args.from_dir.glob('*.csv'))
    if args.site:
        wanted = set(args.site)
        files = [f for f in files
                 if (m := SITE_RE.search(f.name)) and m.group(1) in wanted]
    if not files:
        print(f'No CSV files found in {args.from_dir}', file=sys.stderr)
        return 2
    print(f'{len(files)} candidate files in {args.from_dir}')
    written = 0
    for f in files:
        try:
            if convert(f, meta, args.outdir, args.overwrite):
                written += 1
        except Exception as exc:                      # noqa: BLE001
            print(f'  {f.name}: FAILED -- {type(exc).__name__}: {exc}')
    print(f'{written}/{len(files)} converted into {args.outdir}')
    return 0 if written else 1


if __name__ == '__main__':
    raise SystemExit(main())
