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
import html
import json
import re
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import xarray as xr

DEFAULT_FLUX_DIR = Path('flux/PLUMBER2_original')
DEFAULT_MODEL_DIR = Path('postprocessed')
DEFAULT_SOIL_DIR = Path('soil/PLUMBER2_original')
DEFAULT_CH4_DIR = Path('flux/fluxnet-ch4')
DEFAULT_OUT_DIR = Path('benchmark')
# Country per site, for the towers whose flux file carries no `country`
# attribute -- FluxnetLSM only supplies one for the ~874 sites in its bundled
# metadata, which leaves 475 of the 775 Shuttle sites blank. Built from the site
# coordinates by scripts/fill_site_country.py; the declared attribute always wins.
DEFAULT_COUNTRY_CSV = Path('reference/site_country.csv')
COUNTRY_BY_SITE: dict[str, str] = {}
REGION_BY_SITE: dict[str, str] = {}
DEFAULT_EXPERIMENT_NAME = 'ecland'
DASHBOARD_TEMPLATE = Path(__file__).parent / 'dashboard_template.html'

# Depth-index-1 (shallowest sensor) only: FLUXNET2015's raw SWC_F_MDS_*/
# TS_F_MDS_* columns carry a depth *index*, not a depth in cm (that lives in
# each site's BADM/BIF metadata, which scripts/extract_soil_ancillary.py does
# not parse), so index 1 is the one depth that can be matched to ecLand's
# level 1 (0-7 cm) without guessing at a real-world depth. See soil/<group>/
# and reference/soil_coverage_<group>.csv.
SOIL_VARIABLES = ('SWC', 'TS')
# FCH4 does not reach this repo through the usual route -- FLUXNET-Shuttle's
# flux files are ONEFlux-derived and ONEFlux has no CH4 branch, so it needs
# its own observation source (scripts/fetch_fluxnet_ch4.py + convert_fluxnet_
# ch4.py -> flux/fluxnet-ch4/), scored the same way as SWC/TS: a separate
# file with its own independent time axis, intersected against the model's.
CH4_VARIABLES = ('FCH4',)
VARIABLES = ('Qle', 'Qh', 'NEE') + CH4_VARIABLES + SOIL_VARIABLES
# kg of carbon m-2 s-1 -> umol CO2 m-2 s-1 (molar mass of carbon = 12.011 g/mol)
NEE_KGC_TO_UMOL = 1e6 / 12.011e-3
# kg of CH4 m-2 s-1 -> nmol CH4 m-2 s-1, the FLUXNET-CH4 unit for FCH4
# (molar mass of methane = 16.043 g/mol). ecLand's CH4flux is documented as a
# mass flux with no species stated; if it turns out to be kg of carbon rather
# than kg of CH4, this constant is the single place to correct -- the factor is
# 16.043/12.011 = 1.34 and it moves bias only, never correlation.
FCH4_KG_TO_NMOL = 1e9 / 16.043e-3
# Per-variable model-side unit conversion onto the observation units.
MODEL_UNIT_SCALE = {'NEE': NEE_KGC_TO_UMOL, 'FCH4': FCH4_KG_TO_NMOL}
KELVIN_TO_C = 273.15
SOIL_RE = re.compile(r'soil_([A-Za-z0-9\-]+)_(\d{4}-\d{4})\.nc$')
# ecLand's level-1 layer bottom (0-7 cm) -- a fixed property of the model's
# soil scheme, not a per-site quantity, so it's hardcoded here to match
# postproc.py's own SOIL_LAYER_BOTTOMS[0] rather than read from each
# postprocessed file's optional SoilLev variable (one of 775 lacks it: a
# stale file predating that field being added to the schema, which crashed
# the whole 775-site run on an unguarded ['SoilLev'] lookup).
SOIL_LEVEL1_THICKNESS_M = 0.07
MIN_BIN_N = 20  # minimum valid half-hours to trust a monthly/diurnal bin
SEASONS = {'DJF': (12, 1, 2), 'MAM': (3, 4, 5), 'JJA': (6, 7, 8), 'SON': (9, 10, 11)}

# Matches both the original PLUMBER2 v1.0 release naming and FluxnetLSM's own
# output naming (e.g. ES-LJu_2011-2012_FLUXNET2015_Flux.nc) -- both put
# <site>_<start-year>-<end-year>_ at the front of the filename.
FLUX_RE = re.compile(r'([A-Za-z0-9\-]+)_(\d{4}-\d{4})_')
# Alternate per-site convention with no period in the filename, e.g.
# local_AT-Neu_fluxnet2015_gl9.AT-Neu.nc -- site is whatever precedes ".nc".
MODEL_RE_NOPERIOD = re.compile(r'.+\.([A-Za-z0-9\-]+)\.nc')
# A line in a --sites-file subset list, with the period suffix optional.
SITE_PERIOD_RE = re.compile(r'^(.+)_(\d{4}-\d{4})$')


def discover_soil_map(soil_dir: Path) -> dict[str, Path]:
    """Site -> its soil_<site>_<Y1>-<Y2>.nc, keyed by site alone.

    Not paired on period like the flux/model match: extract_soil_ancillary.py
    keeps every row with no acceptance filtering, so a site's soil period is
    routinely longer than (and never identical to) its FLUXNET2015 flux
    period from the same tower. process_site() intersects each obs source's
    own time axis against the model's independently, so a period mismatch
    here is not a problem -- only one soil file per site exists anyway.
    """
    if not soil_dir.is_dir():
        return {}
    out: dict[str, Path] = {}
    for f in sorted(soil_dir.glob('*.nc')):
        m = SOIL_RE.match(f.name)
        if m:
            out[m.group(1)] = f
    return out


def discover_ch4_map(ch4_dir: Path) -> dict[str, Path]:
    """Site -> its <site>_<Y1>-<Y2>_FLUXNET2015_Flux.nc under flux/fluxnet-ch4/.

    Same FLUX_RE naming as the main flux pool (convert_fluxnet_ch4.py writes
    the identical convention on purpose, so benchmark.py needs no special-
    casing to read it) -- but a different, usually shorter, period: the
    FLUXNET-CH4 Community Product only covers each site's CH4 deployment,
    not its full FLUXNET record. Keyed by site alone for the same reason as
    discover_soil_map: process_site() intersects this file's own time axis
    against the model's independently, so the period need not match.
    """
    if not ch4_dir.is_dir():
        return {}
    out: dict[str, Path] = {}
    for f in sorted(ch4_dir.glob('*.nc')):
        m = FLUX_RE.match(f.name)
        if m:
            out[m.group(1)] = f
    return out


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
    # Fall back to pairing on the site alone when the periods differ. The model
    # run covers whatever the forcing offered, which need not be the period the
    # observations cover -- FLUXNET-CH4 records rarely match the shuttle run
    # exactly (e.g. obs US-Los 2015-2016 against a model 2001-2024). Scoring
    # intersects the two time axes anyway, so a period mismatch is only a naming
    # problem; requiring equality here would silently find zero pairs. Only
    # unambiguous cases are paired: exactly one unmatched model file for the site.
    unmatched = [k for k in flux_map if k not in model_map]
    by_site: dict[str, list[tuple[str, Path]]] = {}
    for (site, period), path in model_map.items():
        by_site.setdefault(site, []).append((period, path))
    for (site, period) in unmatched:
        candidates = by_site.get(site, [])
        if len(candidates) == 1:
            mod_period, path = candidates[0]
            model_map[(site, period)] = path
            # Drop the original key, or the same file is reported below as a
            # model run with no observations -- it has some, under another period.
            model_map.pop((site, mod_period), None)
            print(f'  pairing {site}: observations {period} against model '
                  f'{mod_period} (scored on their overlap)')
        elif len(candidates) > 1:
            print(f'  {site}: {len(candidates)} model periods and no exact match '
                  f'for observations {period}, skipped')
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


def time_keys(ts: pd.DatetimeIndex, season_of_month: dict[int, str]) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    month_key = ts.month.values - 1
    hour_key = np.round(ts.hour.values + ts.minute.values / 60.0).astype(int) % 24
    season_key = np.array([season_of_month[m] for m in ts.month.values])
    year_month = ts.strftime('%Y-%m').values
    return month_key, hour_key, season_key, year_month


def empty_var_record() -> dict[str, Any]:
    return {
        'metrics': {'n': 0, 'bias': None, 'rmse': None, 'r': None, 'nme': None,
                    'std_obs': None, 'std_mod': None, 'pct_measured': None},
        'monthly_clim': {'obs': [None] * 12, 'mod': [None] * 12},
        'diurnal': {s: {'obs': [None] * 24, 'mod': [None] * 24} for s in SEASONS},
        'trend': {'labels': [], 'obs': [], 'mod': []},
    }


def score_series(obs_raw: np.ndarray, mod_raw: np.ndarray, qc: np.ndarray,
                  ts: pd.DatetimeIndex, season_of_month: dict[int, str]) -> dict[str, Any]:
    """Shared scoring path for one variable's already-aligned obs/mod arrays."""
    good = (qc == 0) & np.isfinite(obs_raw) & np.isfinite(mod_raw)
    pct_measured = nanround(100.0 * good.sum() / good.size, 1) if good.size else 0.0
    obs_g, mod_g = obs_raw[good], mod_raw[good]
    metrics = compute_metrics(obs_g, mod_g)
    metrics['pct_measured'] = pct_measured
    out: dict[str, Any] = {'metrics': {k: (nanround(v, 4) if isinstance(v, float) else v)
                                        for k, v in metrics.items()}}

    mk, hk, sk, ym = time_keys(ts, season_of_month)
    mk, hk, sk, ym = mk[good], hk[good], sk[good], ym[good]

    obs_month, mod_month = binned_mean(obs_g, mk, 12), binned_mean(mod_g, mk, 12)
    out['monthly_clim'] = {'obs': [nanround(v, 3) for v in obs_month],
                            'mod': [nanround(v, 3) for v in mod_month]}

    diurnal = {}
    for season in SEASONS:
        smask = sk == season
        obs_h = binned_mean(obs_g[smask], hk[smask], 24)
        mod_h = binned_mean(mod_g[smask], hk[smask], 24)
        diurnal[season] = {'obs': [nanround(v, 3) for v in obs_h], 'mod': [nanround(v, 3) for v in mod_h]}
    out['diurnal'] = diurnal

    uniq_ym, ym_idx = np.unique(ym, return_inverse=True)
    obs_ym = binned_mean(obs_g, ym_idx, uniq_ym.size, min_n=10)
    mod_ym = binned_mean(mod_g, ym_idx, uniq_ym.size, min_n=10)
    out['trend'] = {'labels': uniq_ym.tolist(),
                     'obs': [nanround(v, 3) for v in obs_ym], 'mod': [nanround(v, 3) for v in mod_ym]}
    return out


def pick_depth_var(soil_ds: xr.Dataset, prefix: str, target_depth_m: float) -> tuple[str | None, float | None]:
    """The soil_ds column of the given prefix ('SWC'/'TS') closest in depth to target_depth_m.

    extract_soil_ancillary.py tags each column with a depth_m attribute read
    from the tower's own BADM metadata (VAR_INFO_HEIGHT) -- not always index 1:
    e.g. US-Ton's SWC_1 is 0.001 m but SWC_2..4 are 0.2/0.25/0.5 m, and its
    TS_1..5 span 0.02-0.32 m, crossing all four of ecLand's soil layers. Falls
    back to index 1 only if no column carries depth metadata at all (an older
    extraction, or a hub BADM export missing VAR_INFO_HEIGHT).
    """
    candidates = []
    for name, da in soil_ds.data_vars.items():
        if name.startswith(f'{prefix}_') and not name.endswith('_qc') and 'depth_m' in da.attrs:
            candidates.append((name, float(da.attrs['depth_m'])))
    if not candidates:
        fallback = f'{prefix}_1'
        return (fallback, None) if fallback in soil_ds else (None, None)
    return min(candidates, key=lambda t: abs(t[1] - target_depth_m))


def process_site(site: str, period: str, flux_path: Path, model_path: Path,
                  soil_path: Path | None = None, ch4_path: Path | None = None) -> dict[str, Any] | None:
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
    season_of_month = {m: s for s, months in SEASONS.items() for m in months}

    record = {
        'site': site,
        'site_name': obs_ds.attrs.get('site_name', site),
        'country': COUNTRY_BY_SITE.get(site) or (obs_ds.attrs.get('country', '') or '').strip(),
        'region': REGION_BY_SITE.get(site, ''),
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
        if var in SOIL_VARIABLES or var in CH4_VARIABLES:
            continue
        # A variable is unavailable if either side lacks it. The model side was
        # always handled; the observation side matters here because 50 of the 775
        # Shuttle towers report no NEE at all (and so no NEE_qc). Scoring needs
        # the QC flags to keep measured, non-gapfilled half-hours only, so a
        # missing pair is reported as unavailable rather than scored unfiltered.
        if var not in mod_ds or var not in obs_ds or f'{var}_qc' not in obs_ds:
            r = empty_var_record()
            record['metrics'][var], record['monthly_clim'][var] = r['metrics'], r['monthly_clim']
            record['diurnal'][var], record['trend'][var] = r['diurnal'], r['trend']
            continue
        qc = obs_ds[f'{var}_qc'].values.squeeze()[obs_idx]
        obs_raw = obs_ds[var].values.squeeze()[obs_idx].astype(np.float64)
        mod_raw = mod_ds[var].values.squeeze()[mod_idx].astype(np.float64)
        if var in MODEL_UNIT_SCALE:
            mod_raw = mod_raw * MODEL_UNIT_SCALE[var]

        r = score_series(obs_raw, mod_raw, qc, ts, season_of_month)
        record['metrics'][var], record['monthly_clim'][var] = r['metrics'], r['monthly_clim']
        record['diurnal'][var], record['trend'][var] = r['diurnal'], r['trend']

    # SWC/TS: a separate observation file with its own independent time axis
    # (extract_soil_ancillary.py keeps every row, no acceptance filtering, so
    # its period is routinely longer than the flux file's from the same
    # tower), scored against ecLand's shallowest soil layer (0-7 cm).
    soil_ds = None
    if soil_path is not None:
        try:
            cand = xr.open_dataset(soil_path)
            soil_time = clean_time_axis(cand['time'].values)
            s_common, s_obs_idx, s_mod_idx = np.intersect1d(soil_time, mod_time, return_indices=True)
            if s_common.size >= MIN_BIN_N:
                soil_ds = cand
            else:
                cand.close()
        except Exception:
            soil_ds = None

    for var in SOIL_VARIABLES:
        mod_var = 'SoilMoist' if var == 'SWC' else 'SoilTemp'
        obs_col = obs_depth_m = None
        if soil_ds is not None:
            # Target the middle of ecLand's level-1 band (0-7 cm), not its
            # top or bottom, so a depth just past 7 cm isn't penalised
            # against an equally-close shallower one.
            obs_col, obs_depth_m = pick_depth_var(soil_ds, var, SOIL_LEVEL1_THICKNESS_M / 2)
        qc_col = f'{obs_col}_qc' if obs_col else None
        if (soil_ds is None or obs_col is None or obs_col not in soil_ds
                or qc_col not in soil_ds or mod_var not in mod_ds):
            r = empty_var_record()
            record['metrics'][var], record['monthly_clim'][var] = r['metrics'], r['monthly_clim']
            record['diurnal'][var], record['trend'][var] = r['diurnal'], r['trend']
            continue
        qc = soil_ds[qc_col].values.squeeze()[s_obs_idx]
        obs_raw = soil_ds[obs_col].values.squeeze()[s_obs_idx].astype(np.float64)
        mod_raw = mod_ds[mod_var].isel(level=0).values.squeeze()[s_mod_idx].astype(np.float64)
        if var == 'SWC':
            # kg m-2 in a 0-7 cm layer -> volumetric % (water density 1000 kg m-3).
            mod_raw = mod_raw / (SOIL_LEVEL1_THICKNESS_M * 1000.0) * 100.0
        else:
            mod_raw = mod_raw - KELVIN_TO_C

        s_ts = pd.DatetimeIndex(s_common)
        r = score_series(obs_raw, mod_raw, qc, s_ts, season_of_month)
        # Auditable: which column and real-world depth were actually used,
        # since it is not always index 1 -- see pick_depth_var.
        r['metrics']['obs_depth_m'] = nanround(obs_depth_m, 4) if obs_depth_m is not None else None
        r['metrics']['obs_col'] = obs_col
        record['metrics'][var], record['monthly_clim'][var] = r['metrics'], r['monthly_clim']
        record['diurnal'][var], record['trend'][var] = r['diurnal'], r['trend']

    if soil_ds is not None:
        soil_ds.close()

    # FCH4: same independent-time-axis pattern as SWC/TS, from flux/fluxnet-ch4/
    # (scripts/fetch_fluxnet_ch4.py + convert_fluxnet_ch4.py) rather than the
    # main flux file, since no ONEFlux-derived FLUXNET2015 file carries FCH4
    # at all. That converter already rebuilds its QC onto FLUXNET2015
    # semantics (0 = measured), so scoring here is identical to Qle/Qh/NEE.
    ch4_ds = None
    if ch4_path is not None:
        try:
            cand = xr.open_dataset(ch4_path)
            ch4_time = clean_time_axis(cand['time'].values)
            c_common, c_obs_idx, c_mod_idx = np.intersect1d(ch4_time, mod_time, return_indices=True)
            if c_common.size >= MIN_BIN_N:
                ch4_ds = cand
            else:
                cand.close()
        except Exception:
            ch4_ds = None

    if ch4_ds is None or 'FCH4' not in ch4_ds or 'FCH4_qc' not in ch4_ds or 'FCH4' not in mod_ds:
        r = empty_var_record()
        record['metrics']['FCH4'], record['monthly_clim']['FCH4'] = r['metrics'], r['monthly_clim']
        record['diurnal']['FCH4'], record['trend']['FCH4'] = r['diurnal'], r['trend']
    else:
        qc = ch4_ds['FCH4_qc'].values.squeeze()[c_obs_idx]
        obs_raw = ch4_ds['FCH4'].values.squeeze()[c_obs_idx].astype(np.float64)
        mod_raw = mod_ds['FCH4'].values.squeeze()[c_mod_idx].astype(np.float64) * MODEL_UNIT_SCALE['FCH4']
        c_ts = pd.DatetimeIndex(c_common)
        r = score_series(obs_raw, mod_raw, qc, c_ts, season_of_month)
        record['metrics']['FCH4'], record['monthly_clim']['FCH4'] = r['metrics'], r['monthly_clim']
        record['diurnal']['FCH4'], record['trend']['FCH4'] = r['diurnal'], r['trend']

    if ch4_ds is not None:
        ch4_ds.close()
    obs_ds.close()
    mod_ds.close()
    return record


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--flux-dir', type=Path, default=DEFAULT_FLUX_DIR)
    p.add_argument('--soil-dir', type=Path, default=DEFAULT_SOIL_DIR,
                    help='Directory of soil_<site>_<Y1>-<Y2>.nc from scripts/extract_soil_ancillary.py, '
                         'scored as SWC/TS against ecLand level 1. Optional -- a site missing here '
                         'just reports SWC/TS as unavailable, same as a flux variable a tower lacks.')
    p.add_argument('--ch4-dir', type=Path, default=DEFAULT_CH4_DIR,
                    help='Directory of <site>_<Y1>-<Y2>_FLUXNET2015_Flux.nc from '
                         'scripts/convert_fluxnet_ch4.py, scored as FCH4 (default: %(default)s). '
                         'Optional -- a site missing here just reports FCH4 as unavailable.')
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
                    help='Optional text file restricting the benchmark to a curated subset, one '
                         'entry per line: a bare site code (AT-Neu) takes whatever period this '
                         'pool holds, or SITE_period (AT-Neu_2002-2012) pins one period. '
                         'See reference/subset_*.txt.')
    p.add_argument('--run-label', default=None,
                    help='Human-readable pool name shown in the dashboard header and browser tab '
                         '(default: --run-name).')
    p.add_argument('--experiment-name', default=DEFAULT_EXPERIMENT_NAME,
                    help=f'Must match --experiment-name passed to postproc.py, so postprocessed '
                         f'filenames (ecLand_<name>_<site>_<period>.nc) resolve correctly '
                         f'(default: {DEFAULT_EXPERIMENT_NAME}).')
    return p.parse_args()


def read_sites_file(path: Path) -> tuple[set[str], set[tuple[str, str]]]:
    """Parse a curated subset list into (sites-any-period, pinned site/period pairs).

    A line may pin one period (`AT-Neu_2002-2012`) or name a bare site (`AT-Neu`).
    Bare sites are what let a PLUMBER2-era list select the same towers here:
    FLUXNET-Shuttle usually offers more years per site, so the periods in the
    original lists no longer match and pinning them would select nothing.
    """
    any_period: set[str] = set()
    pinned: set[tuple[str, str]] = set()
    for line in path.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        m = SITE_PERIOD_RE.match(line)
        if m:
            pinned.add((m.group(1), m.group(2)))
        else:
            any_period.add(line)
    return any_period, pinned


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
                if row.get('region'):
                    REGION_BY_SITE[row['site']] = row['region']
        print(f'Country lookup: {len(COUNTRY_BY_SITE)} sites from {args.country_csv}')

    pairs = discover_pairs(args.flux_dir, args.model_dir, args.experiment_name)
    soil_map = discover_soil_map(args.soil_dir)
    print(f'Soil observations: {len(soil_map)} sites from {args.soil_dir}'
          if soil_map else f'Soil observations: none found under {args.soil_dir} '
                            f'(SWC/TS will report as unavailable for every site)')
    ch4_map = discover_ch4_map(args.ch4_dir)
    print(f'CH4 observations: {len(ch4_map)} sites from {args.ch4_dir}'
          if ch4_map else f'CH4 observations: none found under {args.ch4_dir} '
                           f'(FCH4 will report as unavailable for every site)')
    if args.site:
        wanted = set(args.site)
        pairs = [p for p in pairs if p[0] in wanted]
    if args.sites_file:
        any_period, pinned = read_sites_file(args.sites_file)
        have_pairs = {(s, p) for s, p, _, _ in pairs}
        have_sites = {s for s, _, _, _ in pairs}
        missing = sorted((any_period - have_sites)
                         | {f'{s}_{p}' for s, p in pinned - have_pairs})
        if missing:
            print(f'Note: {len(missing)} of {len(any_period) + len(pinned)} entries in '
                  f'{args.sites_file} are not in this pool: {" ".join(missing)}')
        pairs = [p for p in pairs if p[0] in any_period or (p[0], p[1]) in pinned]
    print(f'Processing {len(pairs)} site/period pairs...')

    records = []
    rows = []
    for i, (site, period, flux_path, model_path) in enumerate(pairs, 1):
        try:
            rec = process_site(site, period, flux_path, model_path, soil_map.get(site), ch4_map.get(site))
        except Exception as exc:
            # One malformed input (e.g. a stale postprocessed file missing a
            # variable the current schema always writes) must cost one site,
            # not the whole run -- see SOIL_LEVEL1_THICKNESS_M's note on the
            # one 775-site file this has already happened with.
            print(f'  [{i}/{len(pairs)}] {site} {period}: ERROR ({type(exc).__name__}: {exc})')
            continue
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
        'units': {'Qle': 'W m-2', 'Qh': 'W m-2', 'NEE': 'umol m-2 s-1',
                  'FCH4': 'nmol m-2 s-1', 'SWC': '%', 'TS': 'degC'},
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
        out = (template
               .replace('__DATA_JSON__', data_str.replace('</', '<\\/'))
               .replace('__RUN_LABEL__', html.escape(args.run_label or run_name)))
        dashboard_html.write_text(out, encoding='utf-8')
        print(f'Wrote {dashboard_html} ({dashboard_html.stat().st_size / 1e6:.2f} MB)')
    else:
        print(f'Note: {DASHBOARD_TEMPLATE} not found, skipped building the dashboard HTML.')


if __name__ == '__main__':
    main()
