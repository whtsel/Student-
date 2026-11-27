#!/usr/bin/env python3
"""
Reference "player" — behaves like the Flutter app will, from your laptop.

Two jobs:
  1. Prove the licence gate works exactly as the app will implement it.
  2. Demonstrate seek cost: pulling a 10-second window out of the middle of
     a large encrypted lecture touches only the chunks it needs.

    python tools/player_sim.py --lic licenses/ama-mensah.lic --keydir keys \
        --fp A1B2-C3D4-E5F6-7788 --dist dist --list

    python tools/player_sim.py ... --lecture L02 --seek 300 --window 10
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto as cp  # noqa: E402


def fail(msg: str, code: int = 1) -> int:
    print(f"REFUSED: {msg}", file=sys.stderr)
    return code


def load_licence(path: str, pub) -> dict:
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    payload, sig = doc["payload"], doc["sig"]
    if not cp.verify_signature(pub, payload, sig):
        raise cp.CoursePackError("licence signature invalid (edited or forged)")
    if payload.get("v") != cp.FORMAT_VERSION:
        raise cp.CoursePackError("licence version not supported")
    exp = payload.get("expires_at")
    if exp and _dt.date.today() > _dt.date.fromisoformat(exp):
        raise cp.CoursePackError(f"licence expired on {exp}")
    return payload


def main() -> int:
    ap = argparse.ArgumentParser(description="Reference player / licence gate.")
    ap.add_argument("--lic", required=True)
    ap.add_argument("--keydir", default="keys")
    ap.add_argument("--fp", default="", help="this device's code (as the app would compute)")
    ap.add_argument("--dist", default="dist", help="folder holding .enc + manifest")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--lecture", default="")
    ap.add_argument("--seek", type=float, default=None, help="seconds")
    ap.add_argument("--window", type=float, default=10.0, help="seconds to pull")
    args = ap.parse_args()

    pub = cp.load_public_key(args.keydir)
    try:
        payload = load_licence(args.lic, pub)
    except (OSError, KeyError, json.JSONDecodeError, ValueError) as exc:
        return fail(f"cannot read licence: {exc}", 2)
    except cp.CoursePackError as exc:
        return fail(str(exc))

    if args.fp:
        if cp.normalize_fingerprint(args.fp) != payload["fp"]:
            return fail(
                f"this device ({cp.format_fingerprint(args.fp)}) is not the device "
                f"this licence was issued to "
                f"({cp.format_fingerprint(payload['fp'])})"
            )

    print(f"signed in as {payload['name']}  [{payload['lic_id']}]")
    lectures = payload["lectures"]

    if args.list or not args.lecture:
        print(f"\n{'id':<5} {'title':<44} {'dur':>8}  status")
        for l in lectures:
            path = os.path.join(args.dist, l["file"])
            present = os.path.exists(path)
            dur = l.get("duration_s")
            dur_s = f"{int(dur // 60)}m{int(dur % 60):02d}s" if dur else "—"
            print(f"{l['id']:<5} {l['title'][:44]:<44} {dur_s:>8}  "
                  f"{'imported' if present else 'not imported'}")
        if not args.lecture:
            return 0

    want = args.lecture.strip().upper()
    match = next((l for l in lectures if l["id"] == want), None)
    if not match:
        return fail(f"{want} is not unlocked by this licence "
                    f"(unlocked: {', '.join(l['id'] for l in lectures)})")

    path = os.path.join(args.dist, match["file"])
    if not os.path.exists(path):
        return fail(f"{match['file']} not found in {args.dist} — has it been downloaded?")
    key = cp.b64d(match["key"])

    with open(path, "rb") as f:
        header = cp.read_header(f)

        if args.seek is None:
            t0 = time.perf_counter()
            cp.verify_file(f, key)
            dt = time.perf_counter() - t0
            mb = header.plaintext_size / 1024 / 1024
            print(f"\n{match['id']} verified intact: {mb:.1f} MB read + decrypted "
                  f"in {dt * 1000:.0f} ms")
            return 0

        dur = match.get("duration_s") or (header.plaintext_size / 250_000)
        bitrate = header.plaintext_size / max(dur, 1)
        start_b = int(args.seek * bitrate)
        end_b = int(min(header.plaintext_size, (args.seek + args.window) * bitrate))
        if start_b >= header.plaintext_size:
            return fail("seek past end of file")

        t0 = time.perf_counter()
        data = cp.decrypt_range(f, header, key, start_b, end_b)
        dt = time.perf_counter() - t0

        first = start_b // header.chunk_size
        last = (end_b - 1) // header.chunk_size
        touched = last - first + 1
        print(f"\nseek to {args.seek:.0f}s in {match['id']}: "
              f"{len(data) / 1024:.0f} KB of plaintext")
        print(f"  decrypted {touched} of {header.chunk_count} chunks "
              f"({touched / header.chunk_count:.1%} of the file)")
        print(f"  took {dt * 1000:.2f} ms")
        print(f"  full file is {header.plaintext_size / 1024 / 1024:.1f} MB — "
              f"a naive impl would have decrypted all of it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
