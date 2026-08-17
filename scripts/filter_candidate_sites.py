#!/usr/bin/env python3
"""Filter a fluxnet-shuttle `listall` snapshot CSV down to candidate sites.

Given a live Shuttle snapshot (`fluxnet-shuttle listall`), select sites by IGBP
class, exclude any already present in a reference site-ID list (e.g. the
original PLUMBER2 170, see reference/plumber2_170_site_ids.txt), and rank the
survivors by record length within each data hub.

This is the exact filtering logic validated against the real 2026-08-17 Shuttle
snapshot (775 sites: AmeriFlux 381, ICOS 342, TERN 52) for the fire/vegetation-
stress pilot shortlist -- productized here as a reusable CLI instead of an
ad-hoc script.

Usage
-----
    fluxnet-shuttle listall
    python3 scripts/filter_candidate_sites.py \
        fluxnet_shuttle_snapshot_*.csv \
        --igbp SAV WSA OSH CSH GRA \
        --exclude-file reference/plumber2_170_site_ids.txt \
        --top 20 \
        --out reference/candidate_sites.csv
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("snapshot_csv", type=Path, help="Shuttle listall snapshot CSV.")
    p.add_argument("--igbp", nargs="+", default=None,
                   help="IGBP short codes to keep (default: keep all). "
                        "e.g. --igbp SAV WSA OSH CSH GRA for fire/vegetation-stress biomes.")
    p.add_argument("--exclude-file", type=Path, default=None,
                   help="Text file, one site_id per line (optionally SITE_period, only the "
                        "SITE part before the first '_' is used) -- these sites are dropped. "
                        "e.g. reference/plumber2_170_site_ids.txt")
    p.add_argument("--min-years", type=int, default=0,
                   help="Drop sites with fewer than this many years between first_year/last_year "
                        "(default: 0, i.e. no minimum). PLUMBER2-style QC needs multi-year "
                        "records to survive gap-fill screening -- see FluxnetLSM's min_yrs option.")
    p.add_argument("--top", type=int, default=None,
                   help="Keep only the top N candidates after ranking (default: keep all).")
    p.add_argument("--hub-priority", nargs="+", default=None,
                   help="Data hub names in priority order (e.g. --hub-priority TERN ICOS "
                        "AmeriFlux to favor underrepresented hubs first). Default: no hub "
                        "priority, rank by record length only.")
    p.add_argument("--out", type=Path, default=None,
                   help="Output CSV path (default: print a summary table to stdout only).")
    return p.parse_args()


def load_exclude_ids(path: Path) -> set[str]:
    ids = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ids.add(line.split("_", 1)[0])
    return ids


def main() -> int:
    args = parse_args()

    if not args.snapshot_csv.is_file():
        print(f"ERROR: snapshot CSV not found: {args.snapshot_csv}", file=sys.stderr)
        return 1

    exclude_ids: set[str] = set()
    if args.exclude_file:
        if not args.exclude_file.is_file():
            print(f"ERROR: exclude file not found: {args.exclude_file}", file=sys.stderr)
            return 1
        exclude_ids = load_exclude_ids(args.exclude_file)

    igbp_keep = set(args.igbp) if args.igbp else None

    rows = list(csv.DictReader(open(args.snapshot_csv)))
    if not rows:
        print("ERROR: snapshot CSV has no rows", file=sys.stderr)
        return 1
    missing_cols = {"site_id", "data_hub", "igbp", "first_year", "last_year"} - set(rows[0].keys())
    if missing_cols:
        print(f"ERROR: snapshot CSV missing expected column(s): {sorted(missing_cols)}", file=sys.stderr)
        return 1

    # Dedupe by site_id, keeping the row with the longest record (a site can
    # appear once per FLUXNET product in the snapshot).
    by_site: dict[str, dict] = {}
    for r in rows:
        sid = r["site_id"]
        try:
            nyears = int(r["last_year"]) - int(r["first_year"]) + 1
        except (TypeError, ValueError):
            nyears = 0
        r["_nyears"] = nyears
        if sid not in by_site or nyears > by_site[sid]["_nyears"]:
            by_site[sid] = r

    candidates = [
        r for r in by_site.values()
        if r["site_id"] not in exclude_ids
        and (igbp_keep is None or r["igbp"] in igbp_keep)
        and r["_nyears"] >= args.min_years
    ]

    if args.hub_priority:
        hub_rank = {hub: i for i, hub in enumerate(args.hub_priority)}

        def sort_key(r):
            return (hub_rank.get(r["data_hub"], len(hub_rank)), -r["_nyears"])
    else:
        def sort_key(r):
            return -r["_nyears"]

    candidates.sort(key=sort_key)
    if args.top:
        candidates = candidates[: args.top]

    print(f"{len(by_site)} unique sites in snapshot -> {len(candidates)} candidates "
          f"(igbp={sorted(igbp_keep) if igbp_keep else 'any'}, "
          f"excluded={len(exclude_ids)}, min_years={args.min_years})\n")
    print(f"{'site_id':10} {'hub':10} {'igbp':5} {'years':12} {'nyears':6} {'lat':>9} {'lon':>9}  site_name")
    for r in candidates:
        print(f"{r['site_id']:10} {r['data_hub']:10} {r['igbp']:5} "
              f"{r['first_year']}-{r['last_year']:<6} {r['_nyears']:<6} "
              f"{r['location_lat']:>9} {r['location_long']:>9}  {r['site_name']}")

    if args.out:
        fieldnames = ["site_id", "data_hub", "site_name", "location_lat", "location_long",
                      "igbp", "network", "first_year", "last_year", "download_link"]
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with open(args.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            w.writeheader()
            for r in candidates:
                w.writerow({k: r.get(k, "") for k in fieldnames})
        print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
