#!/usr/bin/env python3
"""Benchmark postprocessed ecLand runs against FLUXNET2015-schema flux observations.

Forked from plumber2-ecland's benchmark_plumber2.py: scoring logic is unchanged, but
the "PLUMBER2" tag in postprocessed-output filenames is now a CLI option
(--experiment-name, must match postproc.py's --experiment-name) instead of a
hardcoded literal, so this works against any site group's flux/model output, not
just the original 170-site benchmark.

For each site/period, compares Qle, Qh and NEE against the FLUXNET2015-derived
observations in --flux-dir, using only quality-controlled (measured,
non-gapfilled) observation timesteps. Writes a per-site metrics table and a compact
JSON of climatology/diurnal/trend aggregates for the benchmark dashboard.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import xarray as xr

DEFAULT_FLUX_DIR = Path('flux/PLUMBER2_original')
DEFAULT_MODEL_DIR = Path('postprocessed')
DEFAULT_OUT_DIR = Path('benchmark')
# Country per site, for the towers whose flux file carries no `country`
# attribute -- FluxnetLSM only supplies one for the ~874 sites in its bundled
# metadata, which leaves 475 of the 775 Shuttle sites blank. Built from the site
# coordinates by scripts/fill_site_country.py; the declared attribute always wins.
DEFAULT_COUNTRY_CSV = Path('reference/site_country.csv')
COUNTRY_BY_SITE: dict[str, str] = {}
DEFAULT_EXPERIMENT_NAME = 'ecland'
DASHBOARD_TEMPLATE = Path(__file__).parent / 'dashboard_template.html'

VARIABLES = ('Qle', 'Qh', 'NEE')
# kg of carbon m-2 s-1 -> umol CO2 m-2 s-1 (molar mass of carbon = 12.011 g/mol)
NEE_KGC_TO_UMOL = 1e6 / 12.011e-3
MIN_BIN_N = 20  # minimum valid half-hours to trust a monthly/diurnal bin
SEASONS = {'DJF': (12, 1, 2), 'MAM': (3, 4, 5), 'JJA': (6, 7, 8), 'SON': (9, 10, 11)}

# Matches both the original PLUMBER2 v1.0 release naming and FluxnetLSM's own
# output naming (e.g. ES-LJu_2011-2012_FLUXNET2015_Flux.nc) -- both put
# <site>_<start-year>-<end-year>_ at the front of the filename.
FLUX_RE = re.compile(r'([A-Za-z0-9\-]+)_(\d{4}-\d{4})_')
# Alternate per-site convention with no period in the filename, e.g.
# local_AT-Neu_fluxnet2015_gl9.AT-Neu.nc -- site is whatever precedes ".nc".
MODEL_RE_NOPERIOD = re.compile(r'.+\.([A-Za-z0-9\-]+)\.nc')


def discover_pairs(flux_dir: Path, model_dir: Path, experiment_name: str) -> list[tuple[str, str, Path, Path]]:
    # postproc.py-schema output, e.g. ecLand_<experiment_name>_AT-Neu_2002-2012.nc
    model_re = re.compile(rf'.*_{re.escape(experiment_name)}_([A-Za-z0-9\-]+)_(\d{{4}}-\d{{4}})\.nc')
    flux_map = {}
    for f in sorted(flux_dir.glob('*.nc')):
        m = FLUX_RE.match(f.name)
        if m:
            flux_map[(m.group(1), m.group(2))] = f
    model_map = {}
    site_only_map = {}
    for f in sorted(model_dir.glob('*.nc')):
        m = model_re.match(f.name)
        if m:
            model_map[(m.group(1), m.group(2))] = f
            continue
        m = MODEL_RE_NOPERIOD.match(f.name)
        if m:
            site_only_map[m.group(1)] = f
    # Site-only files (no period in the filename) are paired against whichever
    # flux period exists for that site -- PLUMBER2 has exactly one period per site.
    for (site, period) in list(flux_map):
        if site in site_only_map and (site, period) not in model_map:
            model_map[(site, period)] = site_only_map[site]
    common = sorted(set(flux_map) & set(model_map))
    missing_model = sorted(set(flux_map) - set(model_map))
    missing_flux = sorted(set(model_map) - set(flux_map))
    if missing_model:
        print(f'Skipping {len(missing_model)} sites with no model output: {missing_model}')
    if missing_flux:
        print(f'Skipping {len(missing_flux)} sites with no flux observations: {missing_flux}')
    return [(site, period, flux_map[(site, period)], model_map[(site, period)]) for site, period in common]


def decode_char_var(ds: xr.Dataset, name: str, default: str = '') -> str:
    # Optional by necessity: 10 of the 775 Shuttle towers carry no
    # IGBP_veg_short and 2 no IGBP_veg_long. The dashboard groups sites by
    # biome, so return a visible placeholder rather than '' -- an empty key
    # would show up as an unlabelled biome group.
    if name not in ds:
        return default
    return ds[name].values.tobytes().decode(errors='ignore').strip('\x00').strip()


def nanround(x: Any, ndigits: int) -> float | None:
    if x is None or (isinstance(x, float) and np.isnan(x)):
        return None
    return round(float(x), ndigits)


def binned_mean(values: np.ndarray, keys: np.ndarray, n_keys: int, min_n: int = MIN_BIN_N) -> np.ndarray:
    out = np.full(n_keys, np.nan)
    for k in range(n_keys):
        sel = values[keys == k]
        if sel.size >= min_n:
            out[k] = np.nanmean(sel)
    return out


def compute_metrics(obs: np.ndarray, mod: np.ndarray) -> dict[str, float | int | None]:
    n = obs.size
    if n < MIN_BIN_N:
        return {'n': n, 'bias': None, 'rmse': None, 'r': None, 'nme': None, 'std_obs': None, 'std_mod': None}
    diff = mod - obs
    obs_anom_abs_sum = np.sum(np.abs(obs - obs.mean()))
    nme = float(np.sum(np.abs(diff)) / obs_anom_abs_sum) if obs_anom_abs_sum > 0 else None
    r = float(np.corrcoef(obs, mod)[0, 1]) if np.std(obs) > 0 and np.std(mod) > 0 else None
    return {
        'n': int(n),
        'bias': float(diff.mean()),
        'rmse': float(np.sqrt(np.mean(diff ** 2))),
        'r': r,
        'nme': nme,
        'std_obs': float(obs.std()),
        'std_mod': float(mod.std()),
    }


def clean_time_axis(times: np.ndarray) -> np.ndarray:
    """Reconstruct an exact, uniformly-spaced time axis.

    Some models (e.g. JULES) store time as float32 seconds-since-epoch. A
    float32 mantissa only has ~7 significant digits, so once the elapsed
    seconds count grows large (multi-year, hourly-or-finer records) each
    stored timestamp can be off by tens of seconds -- and because timestamps
    are computed as t0 + n*step, that rounding error *accumulates* with n
    rather than staying bounded. Over a 15-20 year record the drift can grow
    to exceed a full step, so rounding each timestamp independently (e.g. to
    the nearest minute) isn't always enough to recover exact alignment.
    PLUMBER2 records are fixed-cadence by construction, so instead of
    trusting each stored value, take the first timestamp and the (rounded)
    median step size and regenerate a clean, drift-free axis from those.
    """
    ns = times.astype('datetime64[ns]').astype(np.int64)
    minute_ns = 60_000_000_000
    if ns.size < 2:
        return (np.round(ns / minute_ns).astype(np.int64) * minute_ns).astype('datetime64[ns]')
    step_ns = int(np.round(np.median(np.diff(ns)) / minute_ns)) * minute_ns
    if step_ns <= 0:
        return (np.round(ns / minute_ns).astype(np.int64) * minute_ns).astype('datetime64[ns]')
    t0_ns = int(np.round(ns[0] / minute_ns)) * minute_ns
    return (t0_ns + step_ns * np.arange(ns.size, dtype=np.int64)).astype('datetime64[ns]')


def process_site(site: str, period: str, flux_path: Path, model_path: Path) -> dict[str, Any] | None:
    obs_ds = xr.open_dataset(flux_path)
    mod_ds = xr.open_dataset(model_path)

    obs_time = clean_time_axis(obs_ds['time'].values)
    mod_time = clean_time_axis(mod_ds['time'].values)
    common_time, obs_idx, mod_idx = np.intersect1d(obs_time, mod_time, return_indices=True)
    if common_time.size < MIN_BIN_N:
        obs_ds.close(); mod_ds.close()
        return None

    ts = pd.DatetimeIndex(common_time)
    # Derive the actual cadence rather than assuming half-hourly: a handful of
    # PLUMBER2 sites (e.g. US-Ha1) are hourly, and hardcoding 48 steps/day
    # would silently halve their reported site-years.
    if common_time.size >= 2:
        step_s = float(np.median(np.diff(common_time.astype('datetime64[s]').astype(np.int64))))
        steps_per_day = 86400.0 / step_s if step_s > 0 else 48.0
    else:
        steps_per_day = 48.0
    month_key = ts.month.values - 1
    hour_key = np.round(ts.hour.values + ts.minute.values / 60.0).astype(int) % 24
    season_of_month = {m: s for s, months in SEASONS.items() for m in months}
    season_key = np.array([season_of_month[m] for m in ts.month.values])
    year_month = ts.strftime('%Y-%m').values

    record = {
        'site': site,
        'site_name': obs_ds.attrs.get('site_name', site),
        'country': (obs_ds.attrs.get('country', '') or '').strip() or COUNTRY_BY_SITE.get(site, ''),
        'igbp': decode_char_var(obs_ds, 'IGBP_veg_short', 'UNK'),
        'igbp_long': decode_char_var(obs_ds, 'IGBP_veg_long', 'Unknown'),
        'lat': nanround(float(obs_ds['latitude'].values.squeeze()), 4),
        'lon': nanround(float(obs_ds['longitude'].values.squeeze()), 4),
        # Optional: PLUMBER2's FluxnetLSM output carries elevation, the FLUXNET
        # Shuttle pipeline's does not (it has reference_height instead). It is
        # dashboard metadata, so absence must not cost the whole site.
        'elevation': (nanround(float(obs_ds['elevation'].values.squeeze()), 1)
                      if 'elevation' in obs_ds else None),
        'period': period,
        'years': nanround(common_time.size / (steps_per_day * 365.25), 2),
        'metrics': {},
        'monthly_clim': {},
        'diurnal': {},
        'trend': {},
    }

    for var in VARIABLES:
        # A variable is unavailable if either side lacks it. The model side was
        # always handled; the observation side matters here because 50 of the 775
        # Shuttle towers report no NEE at all (and so no NEE_qc). Scoring needs
        # the QC flags to keep measured, non-gapfilled half-hours only, so a
        # missing pair is reported as unavailable rather than scored unfiltered.
        if var not in mod_ds or var not in obs_ds or f'{var}_qc' not in obs_ds:
            record['metrics'][var] = {'n': 0, 'bias': None, 'rmse': None, 'r': None, 'nme': None,
                                       'std_obs': None, 'std_mod': None, 'pct_measured': None}
            record['monthly_clim'][var] = {'obs': [None] * 12, 'mod': [None] * 12}
            record['diurnal'][var] = {s: {'obs': [None] * 24, 'mod': [None] * 24} for s in SEASONS}
            record['trend'][var] = {'labels': [], 'obs': [], 'mod': []}
            continue
        qc = obs_ds[f'{var}_qc'].values.squeeze()[obs_idx]
        obs_raw = obs_ds[var].values.squeeze()[obs_idx].astype(np.float64)
        mod_raw = mod_ds[var].values.squeeze()[mod_idx].astype(np.float64)
        if var == 'NEE':
            mod_raw = mod_raw * NEE_KGC_TO_UMOL

        good = (qc == 0) & np.isfinite(obs_raw) & np.isfinite(mod_raw)
        pct_measured = nanround(100.0 * good.sum() / good.size, 1) if good.size else 0.0

        obs_g, mod_g = obs_raw[good], mod_raw[good]
        metrics = compute_metrics(obs_g, mod_g)
        metrics['pct_measured'] = pct_measured
        record['metrics'][var] = {k: (nanround(v, 4) if isinstance(v, float) else v) for k, v in metrics.items()}

        mk, hk, sk, ym = month_key[good], hour_key[good], season_key[good], year_month[good]

        obs_month = binned_mean(obs_g, mk, 12)
        mod_month = binned_mean(mod_g, mk, 12)
        record['monthly_clim'][var] = {
            'obs': [nanround(v, 3) for v in obs_month],
            'mod': [nanround(v, 3) for v in mod_month],
        }

        diurnal = {}
        for season in SEASONS:
            smask = sk == season
            obs_h = binned_mean(obs_g[smask], hk[smask], 24)
            mod_h = binned_mean(mod_g[smask], hk[smask], 24)
            diurnal[season] = {
                'obs': [nanround(v, 3) for v in obs_h],
                'mod': [nanround(v, 3) for v in mod_h],
            }
        record['diurnal'][var] = diurnal

        uniq_ym, ym_idx = np.unique(ym, return_inverse=True)
        obs_ym = binned_mean(obs_g, ym_idx, uniq_ym.size, min_n=10)
        mod_ym = binned_mean(mod_g, ym_idx, uniq_ym.size, min_n=10)
        record['trend'][var] = {
            'labels': uniq_ym.tolist(),
            'obs': [nanround(v, 3) for v in obs_ym],
            'mod': [nanround(v, 3) for v in mod_ym],
        }

    obs_ds.close()
    mod_ds.close()
    return record


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--flux-dir', type=Path, default=DEFAULT_FLUX_DIR)
    p.add_argument('--country-csv', type=Path, default=DEFAULT_COUNTRY_CSV,
                    help=f'Per-site country lookup, used only where the flux file has no '
                         f'country attribute (default: {DEFAULT_COUNTRY_CSV}). Build it with '
                         f'scripts/fill_site_country.py.')
    p.add_argument('--model-dir', type=Path, default=DEFAULT_MODEL_DIR)
    p.add_argument('--out-dir', type=Path, default=DEFAULT_OUT_DIR,
                    help="Base output directory; results are written to <out-dir>/<run-name>/.")
    p.add_argument('--run-name', default=None,
                    help="Subdirectory name under --out-dir (default: 'all', or the --sites-file "
                         "stem if one is given, e.g. --sites-file best20.txt -> <out-dir>/best20/).")
    p.add_argument('--site', action='append', default=None, help='Optional site filter; repeatable.')
    p.add_argument('--sites-file', type=Path, default=None,
                    help='Optional text file with one SITE_period per line (e.g. reference/best20.txt) '
                         'to restrict the benchmark to a curated subset.')
    p.add_argument('--experiment-name', default=DEFAULT_EXPERIMENT_NAME,
                    help=f'Must match --experiment-name passed to postproc.py, so postprocessed '
                         f'filenames (ecLand_<name>_<site>_<period>.nc) resolve correctly '
                         f'(default: {DEFAULT_EXPERIMENT_NAME}).')
    return p.parse_args()


def read_sites_file(path: Path) -> set[tuple[str, str]]:
    wanted = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        site, _, period = line.rpartition('_')
        wanted.add((site, period))
    return wanted


def main() -> None:
    args = parse_args()
    # Keep the full-pool and curated-subset outputs in clearly separate,
    # consistently-named subdirectories rather than mixing the full run
    # directly into --out-dir with the subset nested inside it.
    run_name = args.run_name or (args.sites_file.stem if args.sites_file else 'all')
    out_dir = args.out_dir / run_name
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.country_csv.is_file():
        import csv as _csv
        with args.country_csv.open() as fh:
            for row in _csv.DictReader(fh):
                if row.get('country'):
                    COUNTRY_BY_SITE[row['site']] = row['country']
        print(f'Country lookup: {len(COUNTRY_BY_SITE)} sites from {args.country_csv}')

    pairs = discover_pairs(args.flux_dir, args.model_dir, args.experiment_name)
    if args.site:
        wanted = set(args.site)
        pairs = [p for p in pairs if p[0] in wanted]
    if args.sites_file:
        wanted_pairs = read_sites_file(args.sites_file)
        missing = wanted_pairs - {(s, p) for s, p, _, _ in pairs}
        if missing:
            print(f'Warning: {len(missing)} entries in {args.sites_file} not found among discovered pairs: {sorted(missing)}')
        pairs = [p for p in pairs if (p[0], p[1]) in wanted_pairs]
    print(f'Processing {len(pairs)} site/period pairs...')

    records = []
    rows = []
    for i, (site, period, flux_path, model_path) in enumerate(pairs, 1):
        rec = process_site(site, period, flux_path, model_path)
        if rec is None:
            print(f'  [{i}/{len(pairs)}] {site} {period}: SKIPPED (insufficient overlapping time steps)')
            continue
        records.append(rec)
        for var in VARIABLES:
            m = rec['metrics'][var]
            rows.append({'site': site, 'period': period, 'variable': var, **m})
        print(f'  [{i}/{len(pairs)}] {site} {period}: done')

    metrics_csv = out_dir / 'benchmark_metrics.csv'
    pd.DataFrame(rows).to_csv(metrics_csv, index=False)
    print(f'Wrote {metrics_csv}')

    data_json = out_dir / 'benchmark_data.json'
    data_str = json.dumps({
        'generated': pd.Timestamp.now('UTC').strftime('%Y-%m-%dT%H:%M:%SZ'),
        'variables': list(VARIABLES),
        'units': {'Qle': 'W m-2', 'Qh': 'W m-2', 'NEE': 'umol m-2 s-1'},
        'sites': records,
    }, separators=(',', ':'))
    data_json.write_text(data_str)
    size_mb = data_json.stat().st_size / 1e6
    print(f'Wrote {data_json} ({size_mb:.2f} MB)')

    if DASHBOARD_TEMPLATE.exists():
        dashboard_html = out_dir / 'index.html'
        template = DASHBOARD_TEMPLATE.read_text(encoding='utf-8')
        # data is embedded in a <script type="application/json"> tag; escape "</" so no
        # embedded string (e.g. a stray site name) can prematurely close that tag.
        out = template.replace('__DATA_JSON__', data_str.replace('</', '<\\/'))
        dashboard_html.write_text(out, encoding='utf-8')
        print(f'Wrote {dashboard_html} ({dashboard_html.stat().st_size / 1e6:.2f} MB)')
    else:
        print(f'Note: {DASHBOARD_TEMPLATE} not found, skipped building the dashboard HTML.')


if __name__ == '__main__':
    main()
