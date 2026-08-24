#!/usr/bin/env python3
"""Discover and fetch methane-flux tower data for the `fluxnet-ch4` site group.

CH4 does not reach this repo through the usual route. `fluxnet-shuttle` federates
one product -- ONEFlux-processed FLUXNET FULLSET (`plugins/ameriflux.py` requests
`data_product=FLUXNET, data_variant=FULLSET`; ICOS and TERN parse an
`oneflux_code_version` out of the filenames) -- and ONEFlux has no CH4 branch, so
not one of the 775 shuttle-sourced flux files carries FCH4. Hence a separate
fetch path.

Two sources, because they answer different questions:

  base     AmeriFlux BASE, sites publishing FCH4. Live and growing (118 sites at
           the 2026-08-24 check, against the 45-46 reported in the 2021/2023
           papers), half-hourly, as submitted by each tower team -- no
           cross-network standardisation and no gap-filling of FCH4.

  ch4      FLUXNET-CH4 Community Product v1.0 (Delwiche et al. 2021, ESSD;
           79 sites with half-hourly data, 81 in the release). Standardised
           across AmeriFlux/EuroFlux and gap-filled, so it is the citable
           choice. It is NOT on the AmeriFlux download API -- that API serves
           only `BASE-BADM` and `FLUXNET` (verified against amerifluxr's
           `amf_download_base.R`/`amf_download_fluxnet.R`, which reject anything
           else client-side). It comes from the FLUXNET portal instead, so this
           script ingests an already-downloaded copy rather than pretending to
           automate a request that endpoint will not serve.

ORNL DAAC hosts the *derived* UpCH4 gridded product (doi:10.3334/ORNLDAAC/2253),
not the tower half-hourly data, so it is not a source for this group.

Subcommands
-----------
  discover   Query AmeriFlux's public site_info endpoint (no credentials) and
             write the site inventory + a `--sites-file` list for benchmark.py.
  download   Request BASE-BADM for those sites through AmeriFlux's data_download
             API. Needs YOUR AmeriFlux account: the request is logged against it
             and is governed by the CC-BY-4.0 data policy, so `--accept-policy`
             is required and there is no way to pass it implicitly.
  ingest     Register an already-downloaded FLUXNET-CH4 Community Product
             directory as the group, unpacking per-site archives.

Typical use:

    scripts/fetch_fluxnet_ch4.py discover
    scripts/fetch_fluxnet_ch4.py download --user-id <id> --user-email <mail> \\
        --intended-use model --accept-policy
    scripts/fetch_fluxnet_ch4.py ingest --from-dir ~/downloads/FLUXNET-CH4
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
import urllib.request
import zipfile
from datetime import date
from pathlib import Path
from typing import Any

# amerifluxr's `amf_server()` endpoint map (R/zzz.R): base https://amfcdn.lbl.gov/,
# api/v1 for downloads, api/v2 for the site_info display used by the shuttle.
AMF_BASE = 'https://amfcdn.lbl.gov/'
AMF_SITE_INFO_URL = AMF_BASE + 'api/v2/site_info_display/AmeriFlux'
AMF_DOWNLOAD_URL = AMF_BASE + 'api/v1/data_download'

# The variable name AmeriFlux BASE uses for the methane flux.
CH4_VAR = 'FCH4'

DEFAULT_GROUP = 'fluxnet-ch4'
DEFAULT_INVENTORY = Path('reference/fluxnet_ch4_sites.csv')
DEFAULT_SITES_FILE = Path('reference/subset_fluxnet_ch4.txt')

# amf_download_base.R's mapping of short keys onto the categories the API expects.
INTENDED_USE = {
    'synthesis': 'Research - Multi-site synthesis',
    'remote_sensing': 'Research - Remote sensing',
    'model': 'Research - Land model/Earth system model',
    'other_research': 'Research - Other',
    'education': 'Education (Teacher or Student)',
    'other': 'Other',
}

INVENTORY_COLUMNS = ('site', 'site_name', 'lat', 'lon', 'elevation', 'igbp',
                     'country', 'state', 'tower_start', 'tower_end',
                     'base_start', 'base_end', 'base_years', 'has_fch4',
                     'declares_ch4', 'networks')


def http_get_json(url: str, timeout: int = 120) -> Any:
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as fh:
        return json.load(fh)


def http_post_json(url: str, body: dict, timeout: int = 300) -> Any:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as fh:
        return json.load(fh)


def _first(d: dict, *keys: str, default: Any = '') -> Any:
    """AmeriFlux's site_info nests differently per group; take the first hit."""
    for k in keys:
        if k in d and d[k] not in (None, ''):
            return d[k]
    return default


def site_rows(values: list[dict]) -> list[dict]:
    """Flatten the site_info payload, keeping only what the group needs.

    Deliberately drops `grp_team_member`, which carries names and email
    addresses of tower PIs -- personal data with no use here, and not something
    to commit into the repo.
    """
    rows = []
    for s in values:
        base_vars = s.get('base_variables') or []
        declared = s.get('flux_measurements_variables') or []
        loc = s.get('grp_location') or {}
        if isinstance(loc, list):
            loc = loc[0] if loc else {}
        igbp = s.get('grp_igbp') or {}
        if isinstance(igbp, list):
            igbp = igbp[0] if igbp else {}
        dates = s.get('tower_dates') or {}
        if isinstance(dates, list):
            dates = dates[0] if dates else {}
        # grp_network is a plain list of network names; grp_publish_base is the
        # list of years actually published, which is what bounds a usable record
        # (tower_end is null for any still-running site).
        nets = [n if isinstance(n, str) else n.get('network_name', '')
                for n in (s.get('grp_network') or [])]
        pub = [y for y in (s.get('grp_publish_base') or []) if isinstance(y, int)]
        rows.append({
            'site': s.get('site_id', ''),
            'site_name': s.get('site_name', ''),
            'lat': _first(loc, 'latitude', 'location_lat'),
            'lon': _first(loc, 'longitude', 'location_long'),
            'elevation': _first(loc, 'elevation', 'location_elev'),
            'igbp': _first(igbp, 'igbp', 'IGBP'),
            'country': s.get('country', ''),
            'state': s.get('state', ''),
            'tower_start': _first(dates, 'tower_start', 'start_year'),
            'tower_end': _first(dates, 'tower_end', 'end_year'),
            'base_start': min(pub) if pub else '',
            'base_end': max(pub) if pub else '',
            'base_years': len(pub),
            'has_fch4': CH4_VAR in base_vars,
            'declares_ch4': any('CH4' in str(v) for v in declared),
            'networks': ';'.join(n for n in nets if n),
        })
    return rows


def cmd_discover(args: argparse.Namespace) -> int:
    print(f'Querying {AMF_SITE_INFO_URL} ...')
    payload = http_get_json(AMF_SITE_INFO_URL)
    values = payload['values'] if isinstance(payload, dict) else payload
    rows = site_rows(values)
    published = [r for r in rows if r['has_fch4']]
    declared_only = [r for r in rows if r['declares_ch4'] and not r['has_fch4']]

    args.inventory.parent.mkdir(parents=True, exist_ok=True)
    with args.inventory.open('w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=INVENTORY_COLUMNS, lineterminator='\n')
        w.writeheader()
        w.writerows(sorted(published, key=lambda r: r['site']))
    print(f'{len(published)} sites publish {CH4_VAR} in BASE -> {args.inventory}')
    print(f'{len(declared_only)} more declare CH4 instrumentation but publish no '
          f'{CH4_VAR} yet (not listed)')

    with args.sites_file.open('w') as fh:
        fh.write(f'# AmeriFlux sites publishing {CH4_VAR} in the BASE product, as of\n'
                 f'# {date.today().isoformat()}.\n'
                 f'# From {AMF_SITE_INFO_URL} via scripts/fetch_fluxnet_ch4.py discover.\n'
                 f'# Bare site codes: benchmark.py --sites-file takes whatever period\n'
                 f'# the pool holds for each. Regenerate to pick up new CH4 towers.\n')
        for r in sorted(published, key=lambda r: r['site']):
            fh.write(r['site'] + '\n')
    print(f'{len(published)} site codes -> {args.sites_file}')

    by_igbp: dict[str, int] = {}
    for r in published:
        by_igbp[r['igbp'] or 'UNK'] = by_igbp.get(r['igbp'] or 'UNK', 0) + 1
    top = sorted(by_igbp.items(), key=lambda kv: -kv[1])
    print('  by IGBP: ' + ', '.join(f'{k} {v}' for k, v in top))
    return 0


def cmd_download(args: argparse.Namespace) -> int:
    if not args.accept_policy:
        print('Refusing to send the request: AmeriFlux data are released under a\n'
              'data-use policy and the request is logged against your account.\n'
              'Re-run with --accept-policy once you have read\n'
              '  https://ameriflux.lbl.gov/data/data-policy/#data-use',
              file=sys.stderr)
        return 2
    sites = read_site_codes(args.sites_file)
    if not sites:
        print(f'No sites in {args.sites_file}; run `discover` first.', file=sys.stderr)
        return 2

    body = {
        'user_id': args.user_id,
        'user_email': args.user_email,
        'data_product': args.data_product,
        'data_policy': args.data_policy,
        'site_ids': sites,
        'intended_use': INTENDED_USE[args.intended_use],
        'description': args.description,
        'is_test': str(bool(args.dry_run)),
    }
    if args.dry_run:
        print('--dry-run, not sending. Request body would be:')
        print(json.dumps({**body, 'site_ids': f'<{len(sites)} sites>'}, indent=2))
        return 0

    print(f'Requesting {args.data_product} for {len(sites)} sites as {args.user_id} ...')
    resp = http_post_json(AMF_DOWNLOAD_URL, body)
    urls = resp.get('data_urls') or []
    if not urls:
        print(f'No data_urls in response: {json.dumps(resp)[:500]}', file=sys.stderr)
        return 1

    out = args.raw_dir or Path(f'raw/{args.group}')
    out.mkdir(parents=True, exist_ok=True)
    print(f'{len(urls)} files -> {out}')
    for i, entry in enumerate(urls, 1):
        url = entry.get('url') if isinstance(entry, dict) else entry
        if not url:
            continue
        dest = out / url.rsplit('/', 1)[-1]
        if dest.exists() and dest.stat().st_size > 0:
            print(f'  [{i}/{len(urls)}] {dest.name}: already present, skipped')
            continue
        print(f'  [{i}/{len(urls)}] {dest.name} ...')
        # .part first, so an interrupted transfer is never mistaken for a
        # complete file by the resume check above.
        tmp = dest.with_suffix(dest.suffix + '.part')
        with urllib.request.urlopen(url, timeout=600) as r, tmp.open('wb') as fh:
            while chunk := r.read(1 << 20):
                fh.write(chunk)
        tmp.rename(dest)
    print(f'Done. Citation and data policy: see the manifest in {out}.')
    return 0


def cmd_ingest(args: argparse.Namespace) -> int:
    src = args.from_dir
    if not src.is_dir():
        print(f'{src} is not a directory', file=sys.stderr)
        return 2
    out = args.raw_dir or Path(f'raw/{args.group}')
    out.mkdir(parents=True, exist_ok=True)
    # The portal ships one outer zip holding a per-site zip each, and each of
    # those holds a directory with the half-hourly (_HH_) and daily (_DD_) CSV.
    # Recurse one level and keep the sub-daily files only: the model is scored
    # at its own timestep, so the daily aggregates would just double the volume.
    zips = sorted(src.rglob('*.zip'))
    csvs = sorted(src.rglob('*.csv'))
    print(f'{len(zips)} archives, {len(csvs)} loose CSVs under {src}')
    n = 0

    def wanted(name: str) -> bool:
        base = Path(name).name
        if not base.lower().endswith('.csv'):
            return False
        return '_HH_' in base or '_HR_' in base or 'META' in base

    def extract(zf: zipfile.ZipFile, label: str) -> int:
        taken = 0
        for m in zf.namelist():
            if not wanted(m):
                continue
            dest = out / Path(m).name
            if dest.exists():
                continue
            with zf.open(m) as fh, dest.open('wb') as o:
                o.write(fh.read())
            taken += 1
        return taken

    for z in zips:
        with zipfile.ZipFile(z) as zf:
            taken = extract(zf, z.name)
            # A zip of zips: pull the inner archives out through a temp file,
            # since ZipFile needs a seekable handle.
            inner = [m for m in zf.namelist() if m.lower().endswith('.zip')]
            for m in inner:
                tmp = out / ('.inner_' + Path(m).name)
                with zf.open(m) as fh, tmp.open('wb') as o:
                    o.write(fh.read())
                try:
                    with zipfile.ZipFile(tmp) as izf:
                        taken += extract(izf, m)
                finally:
                    tmp.unlink(missing_ok=True)
        n += taken
        print(f'  {z.name}: {taken} CSV')
    for c in csvs:
        if not wanted(c.name):
            continue
        dest = out / c.name
        if not dest.exists():
            dest.write_bytes(c.read_bytes())
            n += 1
    print(f'{n} CSV files -> {out}')
    print('Next: convert to the FLUXNET2015 NetCDF schema under flux/'
          f'{args.group}/ before benchmarking (see README, FLUXNET-CH4 group).')
    return 0


def read_site_codes(path: Path) -> list[str]:
    if not path.is_file():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            out.append(line)
    return out


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--group', default=DEFAULT_GROUP,
                   help=f'Site-group name (default: {DEFAULT_GROUP}).')
    p.add_argument('--raw-dir', type=Path, default=None,
                   help='Where raw downloads land (default: raw/<group>/).')
    sub = p.add_subparsers(dest='cmd', required=True)

    d = sub.add_parser('discover', help='List AmeriFlux sites publishing FCH4.')
    d.add_argument('--inventory', type=Path, default=DEFAULT_INVENTORY)
    d.add_argument('--sites-file', type=Path, default=DEFAULT_SITES_FILE)
    d.set_defaults(func=cmd_discover)

    g = sub.add_parser('download', help='Request BASE-BADM from AmeriFlux.')
    g.add_argument('--sites-file', type=Path, default=DEFAULT_SITES_FILE)
    g.add_argument('--user-id', required=True, help='Your AmeriFlux account id.')
    g.add_argument('--user-email', required=True)
    g.add_argument('--data-product', default='BASE-BADM',
                   help='AmeriFlux download API product. The API accepts only '
                        'BASE-BADM and FLUXNET; the FLUXNET-CH4 Community '
                        'Product is not served here -- use `ingest` for it.')
    g.add_argument('--data-policy', default='CCBY4.0', choices=('CCBY4.0', 'LEGACY'))
    g.add_argument('--intended-use', default='model', choices=sorted(INTENDED_USE))
    g.add_argument('--description', default='ecLand land-surface model evaluation '
                                            'of methane flux at FLUXNET towers.')
    g.add_argument('--accept-policy', action='store_true',
                   help='Confirm you accept the AmeriFlux data-use policy. Required.')
    g.add_argument('--dry-run', action='store_true',
                   help='Print the request body and exit without sending.')
    g.set_defaults(func=cmd_download)

    i = sub.add_parser('ingest', help='Register a downloaded FLUXNET-CH4 copy.')
    i.add_argument('--from-dir', type=Path, required=True,
                   help='Directory holding the FLUXNET-CH4 zips/CSVs from '
                        'https://fluxnet.org/data/fluxnet-ch4-community-product/')
    i.set_defaults(func=cmd_ingest)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
