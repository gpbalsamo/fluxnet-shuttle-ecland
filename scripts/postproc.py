#!/usr/bin/env python3
"""Post-process all ecLand site outputs into the common PLUMBER2-style schema.

Forked from plumber2-ecland's postproc_plumber2.py: the schema and processing
logic are unchanged, but the experiment tag baked into output filenames and
NetCDF metadata is now a CLI option (--experiment-name) instead of the
hardcoded literal "PLUMBER2", so this works for any site group (e.g. a
FLUXNET-Shuttle-sourced site list), not just the original 170-site benchmark.
"""
from __future__ import annotations

import argparse
import sys
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
import xarray as xr
from netCDF4 import Dataset as NetCDFDataset

DEFAULT_INPUT_DIR = Path('output')
DEFAULT_OUTPUT_DIR = Path('postprocessed')
DEFAULT_EXPERIMENT_NAME = 'ecland'
FILL = np.float32(-9999.0)
SOIL_LEVELS = np.array([1, 2, 3, 4], dtype=np.int32)
SOIL_LAYER_BOTTOMS = np.array([0.07, 0.28, 1.00, 2.89], dtype=np.float32)

SCHEMA: dict[str, dict[str, Any]] = {
    'Qg': {'dims': ('time',), 'long_name': 'downward heat flux at ground surface', 'units': 'W m-2'},
    'Qgs': {'dims': ('time',), 'long_name': 'downward heat flux in snow', 'units': 'W m-2'},
    'Qle': {'dims': ('time',), 'long_name': 'surface upward latent heat flux', 'units': 'W m-2'},
    'Qfsn': {'dims': ('time',), 'long_name': 'energy of fusion', 'units': 'W m-2'},
    'Qh': {'dims': ('time',), 'long_name': 'surface upward sensible heat flux', 'units': 'W m-2'},
    'LWup': {'dims': ('time',), 'long_name': 'surface upwelling longwave radiation', 'units': 'W m-2'},
    'SWup': {'dims': ('time',), 'long_name': 'surface upwelling shortwave radiation', 'units': 'W m-2'},
    'SWnet': {'dims': ('time',), 'long_name': 'surface net shortwave radiation', 'units': 'W m-2'},
    'Rnet': {'dims': ('time',), 'long_name': 'surface net radiation', 'units': 'W m-2', 'comments': 'SWnet + LWnet'},
    'Evap': {'dims': ('time',), 'long_name': 'total water vapour flux from the surface to the atmosphere', 'units': 'kg m-2 s-1'},
    'ESoil': {'dims': ('time',), 'long_name': 'evaporation and sublimation from soil', 'units': 'kg m-2 s-1'},
    'Qsb': {'dims': ('time',), 'long_name': 'subsurface runoff', 'units': 'kg m-2 s-1'},
    'Qs': {'dims': ('time',), 'long_name': 'surface runoff', 'units': 'kg m-2 s-1'},
    'SubSnow': {'dims': ('time',), 'long_name': 'sublimation of snow', 'units': 'kg m-2 s-1'},
    'Qsm': {'dims': ('time',), 'long_name': 'surface snow melt', 'units': 'kg m-2 s-1'},
    'Tveg': {'dims': ('time',), 'long_name': 'transpiration', 'units': 'kg m-2 s-1'},
    'Albedo': {'dims': ('time',), 'long_name': 'surface albedo', 'units': '-'},
    'SAlbedo': {'dims': ('time',), 'long_name': 'snow albedo', 'units': '-'},
    'CanopInt': {'dims': ('time',), 'long_name': 'total canopy water storage', 'units': 'kg m-2'},
    'SoilMoist': {'dims': ('time', 'level'), 'long_name': 'masses of frozen and unfrozen moisture in soil layers', 'units': 'kg m-2'},
    'SnowFrac': {'dims': ('time',), 'long_name': 'snow area fraction', 'units': '-'},
    'SnowDepth': {'dims': ('time',), 'long_name': 'snowdepth', 'units': 'm'},
    'SWE': {'dims': ('time',), 'long_name': 'mass of snowpack', 'units': 'kg m-2'},
    'VegT': {'dims': ('time',), 'long_name': 'vegetation canopy temperature', 'units': 'K'},
    'BaresoilT': {'dims': ('time',), 'long_name': 'temperature of bare soil', 'units': 'K'},
    'AvgSurfT': {'dims': ('time',), 'long_name': 'surface temperature', 'units': 'K'},
    'SoilTemp': {'dims': ('time', 'level'), 'long_name': 'temperatures of soil layers', 'units': 'K'},
    'SnowT': {'dims': ('time',), 'long_name': 'snow internal temperature', 'units': 'K'},
    'NEE': {'dims': ('time',), 'long_name': 'Net ecosystem exchange', 'units': 'kg m-2 s-1', 'comments': 'kg of carbon'},
    'GPP': {'dims': ('time',), 'long_name': 'Gross primary production', 'units': 'kg m-2 s-1', 'comments': 'kg of carbon'},
    # Sign follows the observations, not ecLand: FLUXNET-CH4 reports FCH4
    # positive upward (emission to atmosphere), while ecLand's o_co2.nc CH4flux
    # is downward-positive like every other flux it writes, so it is negated
    # here exactly as CO2flux -> NEE is.
    'FCH4': {'dims': ('time',), 'long_name': 'Net methane flux', 'units': 'kg m-2 s-1', 'comments': 'kg of CH4, positive upward (emission)'},
    'lai_hv': {'dims': ('time',), 'long_name': 'Leaf Area Index HV', 'units': 'm2 m-2', 'comments': 'LAI disaggregated for high vegetation'},
    'lai_lv': {'dims': ('time',), 'long_name': 'Leaf Area Index LV', 'units': 'm2 m-2', 'comments': 'LAI disaggregated for low vegetation'},
}

MAPPINGS = (
    ('o_co2.nc', 'CO2flux', 'NEE', 'negate'), ('o_co2.nc', 'Ag', 'GPP', None),
    ('o_co2.nc', 'CH4flux', 'FCH4', 'negate'),
    ('o_efl.nc', 'Qg', 'Qg', None), ('o_efl.nc', 'Qgsn', 'Qgs', None),
    ('o_efl.nc', 'Qle', 'Qle', 'negate'), ('o_efl.nc', 'Qfsn', 'Qfsn', None),
    ('o_efl.nc', 'Qh', 'Qh', 'negate'), ('o_efl.nc', 'LWup', 'LWup', 'negate'),
    ('o_efl.nc', 'SWnet', 'SWnet', None),
    ('o_wat.nc', 'Evap', 'Evap', 'negate'), ('o_wat.nc', 'Qsb', 'Qsb', 'negate'),
    ('o_wat.nc', 'Qs', 'Qs', None), ('o_wat.nc', 'Qsm', 'Qsm', None),
    ('o_eva.nc', 'ESoil', 'ESoil', 'negate'), ('o_eva.nc', 'SubSnow', 'SubSnow', 'negate'),
    ('o_eva.nc', 'TVeg', 'Tveg', 'negate'),
    ('o_gg.nc', 'CanopInt', 'CanopInt', None), ('o_gg.nc', 'SWE', 'SWE', None),
    ('o_gg.nc', 'SAlbedo', 'SAlbedo', None), ('o_gg.nc', 'AvgSurfT', 'AvgSurfT', None),
    ('o_gg.nc', 'SnowT', 'SnowT', None), ('o_gg.nc', 'SoilMoist', 'SoilMoist', 'soil'),
    ('o_gg.nc', 'SoilTemp', 'SoilTemp', 'soil'),
    ('o_cld.nc', 'SnowFrac', 'SnowFrac', None), ('o_cld.nc', 'SnowDepth', 'SnowDepth', None),
    ('o_sus.nc', 'VegT', 'VegT', None), ('o_sus.nc', 'BaresoilT', 'BaresoilT', None),
    ('o_sus.nc', 'Albedo', 'Albedo', None),
    ('o_vty.nc', 'lai', 'lai_lv', 'vtype_low'), ('o_vty.nc', 'lai', 'lai_hv', 'vtype_high'),
)
EXPECTED_FILES = sorted({m[0] for m in MAPPINGS})


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Post-process ecLand PLUMBER2 site output.')
    p.add_argument('--inputdir', type=Path, default=DEFAULT_INPUT_DIR)
    p.add_argument('--outdir', type=Path, default=DEFAULT_OUTPUT_DIR)
    p.add_argument('--site', action='append', default=None, help='Optional site filter; repeatable.')
    p.add_argument('--overwrite', action='store_true')
    p.add_argument('--strict', action='store_true')
    p.add_argument('--no-compression', action='store_true')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--experiment-name', default=DEFAULT_EXPERIMENT_NAME,
                    help=f'Tag embedded in output filenames (ecLand_<name>_<site>.nc) and '
                         f'NetCDF metadata; must match --experiment-name passed to benchmark.py '
                         f'(default: {DEFAULT_EXPERIMENT_NAME}).')
    return p.parse_args()


def discover_sites(inputdir: Path, requested: list[str] | None) -> list[Path]:
    if requested:
        sites = [inputdir / name for name in requested]
        missing = [p for p in sites if not p.is_dir()]
        if missing:
            raise FileNotFoundError('Missing site directories:\n' + '\n'.join(map(str, missing)))
        return sorted(sites)
    return [p for p in sorted(inputdir.iterdir()) if p.is_dir() and any((p/f).is_file() for f in EXPECTED_FILES)]


def squeeze_site(da: xr.DataArray) -> xr.DataArray:
    for dim in ('lat', 'lon', 'latitude', 'longitude', 'x', 'y'):
        if dim in da.dims and da.sizes[dim] == 1:
            da = da.squeeze(dim, drop=True)
    return da


def scalar_coord(ds: xr.Dataset, names: tuple[str, ...]) -> float | None:
    for name in names:
        if name in ds:
            vals = np.asarray(ds[name].values).reshape(-1)
            vals = vals[np.isfinite(vals)]
            if vals.size:
                return float(vals[0])
    return None


def transform(da: xr.DataArray, kind: str | None) -> xr.DataArray:
    if kind is None:
        return da
    if kind == 'negate':
        return -da
    if kind == 'soil':
        dim = next((d for d in ('nlevs', 'nlev', 'soil_layer', 'layer', 'level') if d in da.dims), None)
        if dim is None:
            raise ValueError(f'{da.name} has no soil-level dimension')
        return da.rename({dim: 'level'}) if dim != 'level' else da
    if kind in ('vtype_low', 'vtype_high'):
        if 'vtype' not in da.dims or da.sizes['vtype'] < 2:
            raise ValueError(f'{da.name} does not contain two vegetation types')
        return da.isel(vtype=0 if kind == 'vtype_low' else 1, drop=True)
    raise ValueError(kind)



def build_complete_time_axis(site_name: str, time_axes: list[tuple[str, xr.DataArray]]) -> xr.DataArray:
    """Build the complete regular time grid implied by the site period and source cadence."""
    _, longest = max(time_axes, key=lambda item: item[1].size)
    if not np.issubdtype(longest.dtype, np.datetime64) or longest.size < 2:
        return longest

    values = np.asarray(longest.values, dtype="datetime64[ns]")
    values = np.sort(np.unique(values[~np.isnat(values)]))
    if values.size < 2:
        return longest

    deltas = np.diff(values).astype("timedelta64[ns]").astype(np.int64)
    positive = deltas[deltas > 0]
    if positive.size == 0:
        return longest
    step_ns = int(np.median(positive))

    match = re.search(r"_(\d{4})-(\d{4})$", site_name)
    if match:
        start_year, end_year = map(int, match.groups())
        start = np.datetime64(f"{start_year:04d}-01-01T00:00:00", "ns")
        stop = np.datetime64(f"{end_year + 1:04d}-01-01T00:00:00", "ns")
    else:
        start = values[0]
        stop = values[-1] + np.timedelta64(step_ns, "ns")

    complete = np.arange(start, stop, np.timedelta64(step_ns, "ns"), dtype="datetime64[ns]")
    return xr.DataArray(complete, dims=("time",), coords={"time": complete}, name="time")


def process_site(site: Path, output: Path, overwrite: bool, strict: bool, compression: bool, experiment_name: str) -> bool:
    if output.exists() and not overwrite:
        print(f'  SKIP: {output} already exists')
        return False

    loaded: dict[str, xr.Dataset] = {}
    time_axes: list[tuple[str, xr.DataArray]] = []
    lat = lon = None
    try:
        for fname in EXPECTED_FILES:
            path = site / fname
            if not path.is_file():
                msg = f'missing source file: {path}'
                if strict:
                    raise FileNotFoundError(msg)
                print(f'    WARNING: {msg}')
                continue
            print(f'    Reading {fname}')
            ds = xr.open_dataset(path).load()
            loaded[fname] = ds
            if 'time' in ds.coords:
                time_axes.append((fname, ds['time'].copy(deep=True)))
            lat = lat if lat is not None else scalar_coord(ds, ('lat','latitude','station_latitude'))
            lon = lon if lon is not None else scalar_coord(ds, ('lon','longitude','station_longitude'))

        if not time_axes:
            raise RuntimeError('No time coordinate found')
        tfile, longest_time = max(time_axes, key=lambda item: item[1].size)
        time = build_complete_time_axis(site.name, time_axes)
        print('    Time axes: ' + ', '.join(f'{f}={t.size}' for f,t in time_axes))
        print(f'    Longest source axis: {tfile} ({longest_time.size} records)')
        print(f'    Complete target axis: {time.size} records')

        vars_out: dict[str, xr.DataArray] = {}
        for fname, src, dst, kind in MAPPINGS:
            ds = loaded.get(fname)
            if ds is None or src not in ds:
                msg = f'{fname}:{src} unavailable for {dst}'
                if strict:
                    raise KeyError(msg)
                print(f'    WARNING: {msg}')
                continue
            da = squeeze_site(transform(ds[src].copy(deep=True), kind))
            if 'time' in da.dims and not da['time'].identical(time):
                before = da.sizes['time']
                da = da.reindex(time=time)
                print(f'    WARNING: aligned {dst} from {before} to {time.size} records')
            expected = SCHEMA[dst]['dims']
            if set(da.dims) != set(expected):
                raise ValueError(f'{dst}: source dimensions {da.dims}, expected {expected}')
            da = da.transpose(*expected).astype(np.float32)
            if 'level' in da.dims:
                if da.sizes['level'] != 4:
                    raise ValueError(f'{dst} has {da.sizes["level"]} soil levels; expected 4')
                da = da.assign_coords(level=SOIL_LEVELS)
            vars_out[dst] = da

        # Derived SWup; only used because no direct SWup diagnostic exists.
        efl = loaded.get('o_efl.nc')
        if efl is not None and 'SWdown' in efl and 'SWnet' in efl:
            da = squeeze_site((efl['SWdown'] - efl['SWnet']).copy(deep=True))
            if not da['time'].identical(time):
                da = da.reindex(time=time)
            vars_out['SWup'] = da.transpose('time').astype(np.float32)

        # Derived Rnet = SWnet + LWnet.
        if efl is not None and 'SWnet' in efl and 'LWnet' in efl:
            da = squeeze_site((efl['SWnet'] + efl['LWnet']).copy(deep=True))
            if not da['time'].identical(time):
                da = da.reindex(time=time)
            vars_out['Rnet'] = da.transpose('time').astype(np.float32)

        # Fill any unavailable target variable explicitly.
        for name, meta in SCHEMA.items():
            if name in vars_out:
                continue
            shape = tuple(time.size if d == 'time' else 4 for d in meta['dims'])
            coords = {'time': time}
            if 'level' in meta['dims']:
                coords['level'] = SOIL_LEVELS
            vars_out[name] = xr.DataArray(np.full(shape, FILL, dtype=np.float32), dims=meta['dims'], coords=coords)
            print(f'    WARNING: writing {name} entirely as missing')

        out = xr.Dataset({name: vars_out[name] for name in SCHEMA})
        out = out.assign_coords(level=('level', SOIL_LEVELS))
        out['level'].attrs = {'long_name': 'soil level', 'units': 'level'}
        out['SoilLev'] = xr.DataArray(SOIL_LAYER_BOTTOMS, dims=('level',), attrs={
            'long_name': 'Depth of each soil layer (bottom surface)', 'units': 'm', 'comments': 'none'})
        out['latitude'] = xr.DataArray(np.float32(lat if lat is not None else FILL), attrs={
            'long_name': 'latitude of the site', 'units': 'degrees_north', 'comments': 'none'})
        out['longitude'] = xr.DataArray(np.float32(lon if lon is not None else FILL), attrs={
            'long_name': 'latitude of the site', 'units': 'degrees_east', 'comments': 'none'})

        # Split site name into code and period: e.g. "AR-SLu_2010-2010" -> "AR-SLu" + "2010-2010"
        site_full = site.name
        if '_' in site_full:
            site_code, site_period = site_full.rsplit('_', 1)
        else:
            site_code, site_period = site_full, ''
        out['site_period'] = xr.DataArray(np.bytes_(site_period), attrs={
            'long_name': 'simulation period (start_year-end_year)', 'comments': 'none'})

        for name, meta in SCHEMA.items():
            out[name].attrs = {'long_name': meta['long_name'], 'units': meta['units'], 'comments': meta.get('comments', 'none')}
        out['time'].attrs = {'long_name': 'time'}
        out.attrs = {
            'history': f'Created {datetime.now(timezone.utc).isoformat()}',
            'creation': 'postproc_plumber2.py',
            'site': site_code,
            'period': site_period,
            'model': 'ecLand',
            'experiment': experiment_name,
            'source_directory': str(site),
            'source_files': ', '.join(sorted(loaded)),
        }

        encoding: dict[str, dict[str, Any]] = {
            name: {'dtype': 'float32', '_FillValue': FILL} for name in SCHEMA
        }
        encoding['SoilLev'] = {'dtype': 'float32', '_FillValue': FILL}
        encoding['latitude'] = {'dtype': 'float32', '_FillValue': FILL}
        encoding['longitude'] = {'dtype': 'float32', '_FillValue': FILL}
        encoding['site_period'] = {'_FillValue': None}
        encoding['level'] = {'dtype': 'int32'}
        # Preserve ecLand's decoded time values but write the established units.
        if np.issubdtype(out['time'].dtype, np.datetime64):
            year = str(out['time'].dt.year.values[0])
            encoding['time'] = {'dtype': 'float64', 'units': f'seconds since {year}-01-01 00:00:00', '_FillValue': None}
        else:
            encoding['time'] = {'dtype': 'float64', '_FillValue': None}
        if compression:
            for name in list(SCHEMA) + ['SoilLev']:
                encoding[name].update({'zlib': True, 'complevel': 4, 'shuffle': True})

        output.parent.mkdir(parents=True, exist_ok=True)
        out.to_netcdf(output, mode='w', format='NETCDF4', encoding=encoding, unlimited_dims=['time'])

        # Match the established PLUMBER2 time metadata exactly. Xarray otherwise
        # shortens the units string and adds a calendar attribute.
        with NetCDFDataset(output, 'r+') as nc:
            tvar = nc.variables['time']
            if np.issubdtype(out['time'].dtype, np.datetime64):
                year = int(out['time'].dt.year.values[0])
                tvar.setncattr('units', f'seconds since {year:04d}-01-01 00:00:00')
            if 'calendar' in tvar.ncattrs():
                tvar.delncattr('calendar')

        print(f'  WRITTEN: {output}')
        print(f'    Variables : {", ".join(SCHEMA)}')
        print(f'    Time steps: {time.size}')
        return True
    finally:
        for ds in loaded.values():
            ds.close()


def main() -> int:
    args = parse_args()
    inputdir = args.inputdir.expanduser().resolve()
    outdir = args.outdir.expanduser().resolve()
    if not inputdir.is_dir():
        print(f'ERROR: input directory does not exist: {inputdir}', file=sys.stderr)
        return 2
    try:
        sites = discover_sites(inputdir, args.site)
    except OSError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2
    if not sites:
        print(f'ERROR: no ecLand site folders found below {inputdir}', file=sys.stderr)
        return 1

    print('=' * 72)
    print('ecLand post-processing')
    print('=' * 72)
    print(f'Input directory : {inputdir}')
    print(f'Output directory: {outdir}')
    print(f'Experiment name : {args.experiment_name}')
    print(f'Selected sites  : {len(sites)}')
    print(f'Strict mode     : {args.strict}')
    print(f'Compression     : {not args.no_compression}\n')
    if args.dry_run:
        for site in sites:
            print(f'{site} -> {outdir / f"ecLand_{args.experiment_name}_{site.name}.nc"}')
        return 0

    written = skipped = failed = 0
    for i, site in enumerate(sites, 1):
        print(f'[{i}/{len(sites)}] Site: {site.name}')
        try:
            out_file = outdir / f'ecLand_{args.experiment_name}_{site.name}.nc'
            if process_site(site, out_file, args.overwrite, args.strict, not args.no_compression, args.experiment_name):
                written += 1
            else:
                skipped += 1
        except Exception as exc:
            failed += 1
            print(f'  ERROR: {exc}', file=sys.stderr)
            if args.strict:
                return 1
        print()
    print('=' * 72 + '\nSummary\n' + '=' * 72)
    print(f'Written: {written}\nSkipped: {skipped}\nFailed : {failed}')
    return 1 if failed else 0

if __name__ == '__main__':
    raise SystemExit(main())
