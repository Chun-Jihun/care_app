#!/usr/bin/env python3
"""Collect all permit/DUR operations once, then inspect without network or keys."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.fetch_mfds_easy_drug import DownloaderError, load_dotenv, utc_now
from scripts.mfds_catalog import SERVICES, normalize_base
from scripts.mfds_local_store import build_index, lookup
from scripts.mfds_snapshot import collect


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    fetch = subs.add_parser("fetch", help="Full snapshots; API calls happen only here")
    fetch.add_argument("--service", choices=[*SERVICES, "all"], default="all")
    fetch.add_argument("--env-file", type=Path, default=Path(".env"))
    fetch.add_argument("--output-root", type=Path, default=Path("data/mfds"))
    fetch.add_argument("--snapshot-id")
    fetch.add_argument("--resume", action="store_true")
    fetch.add_argument("--num-rows", type=int, default=500)
    fetch.add_argument("--workers", type=int, default=4)
    fetch.add_argument("--delay-seconds", type=float, default=0.25)
    fetch.add_argument("--max-requests", type=int, default=9500,
                       help="Page requests per service per invocation; retries are additional")
    fetch.add_argument("--dry-run", action="store_true")
    index = subs.add_parser("index", help="Build an offline DB from verified complete raw pages")
    index.add_argument("--snapshot", type=Path, required=True)
    query = subs.add_parser("query", help="Offline source lookup; never calls APIs")
    query.add_argument("--snapshot", type=Path, required=True)
    group = query.add_mutually_exclusive_group(required=True)
    group.add_argument("--item-seq")
    group.add_argument("--name")
    query.add_argument("--limit", type=int, default=20)
    return parser


def run(args: argparse.Namespace) -> None:
    if args.command == "query":
        print(json.dumps(lookup(args.snapshot, item_seq=args.item_seq,
                                name=args.name, limit=args.limit), ensure_ascii=False, indent=2))
        return
    if args.command == "index":
        print(build_index(args.snapshot))
        return
    if args.resume and not args.snapshot_id:
        raise DownloaderError("재개할 --snapshot-id를 지정하세요.")
    snapshot_id = args.snapshot_id or utc_now().strftime("%Y%m%dT%H%M%SZ")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", snapshot_id):
        raise DownloaderError("스냅샷 ID 형식이 잘못되었습니다.")
    values = load_dotenv(args.env_file)
    selected = list(SERVICES) if args.service == "all" else [args.service]
    configs = []
    for name in selected:
        service = SERVICES[name]
        key_name = service.env_prefix + "_SERVICE_KEY"
        endpoint_name = service.env_prefix + "_ENDPOINT"
        key = os.environ.get(key_name, values.get(key_name, "")).strip()
        base = normalize_base(os.environ.get(endpoint_name, values.get(endpoint_name, service.endpoint)), service)
        if not key:
            raise DownloaderError(f"{key_name}가 비어 있습니다.")
        configs.append((name, base, key))
    for name, base, key in configs:
        snapshot = args.output_root / name / snapshot_id
        print(f"{name}: {base}; operations={len(SERVICES[name].operations)}; output={snapshot}", flush=True)
        if args.dry_run:
            continue
        # Exclusive writer guard; after an OS crash, inspect before removing a stale guard.
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        lock = snapshot.parent / f".{snapshot_id}.collect.lock"
        with lock.open("x", encoding="ascii") as stream:
            stream.write(str(os.getpid()))
        try:
            collect(snapshot, name, base, key, rows=args.num_rows, workers=args.workers,
                    delay=args.delay_seconds, max_requests=args.max_requests, resume=args.resume)
            print(f"building offline DB: {snapshot}", flush=True)
            print(f"saved: {build_index(snapshot)}", flush=True)
        finally:
            lock.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        run(args)
        return 0
    except KeyboardInterrupt:
        print("수집 중단: 원문을 보존했습니다. 같은 스냅샷으로 재개할 수 있습니다.", file=sys.stderr)
        return 130
    except (DownloaderError, OSError, ValueError, KeyError, TypeError) as exc:
        # Unknown exception text may contain URLs/credentials: only curated errors are shown.
        message = str(exc) if isinstance(exc, DownloaderError) else type(exc).__name__
        print(f"오류: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
