#!/usr/bin/env python3
"""
Check a licence file the way the app will check it, from your laptop.

    python tools/verify_licence.py --lic licenses/ama-mensah.lic --keydir keys
    python tools/verify_licence.py --lic licenses/ama-mensah.lic --fp A1B2-...

Useful when a student says "the app won't open" — you can tell instantly
whether the file is intact, expired, or bound to a different device.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify a CoursePack licence file.")
    ap.add_argument("--lic", required=True)
    ap.add_argument("--keydir", default="keys")
    ap.add_argument("--fp", default="", help="check against a device code")
    args = ap.parse_args()

    try:
        with open(args.lic, encoding="utf-8") as f:
            doc = json.load(f)
        payload = doc["payload"]
        sig = doc["sig"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"FAIL  cannot read licence: {exc}", file=sys.stderr)
        return 2

    pub = cp_crypto.load_public_key(args.keydir)

    if not cp_crypto.verify_signature(pub, payload, sig):
        print("FAIL  signature invalid — file was edited, or signed with a "
              "different private key.", file=sys.stderr)
        return 1

    print("OK    signature valid")
    print(f"      student    : {payload.get('name')}")
    print(f"      licence id : {payload.get('lic_id')}")
    print(f"      course     : {payload.get('course_title')} "
          f"({payload.get('course_id')})")
    print(f"      device     : {cp_crypto.format_fingerprint(payload.get('fp', ''))}")
    print(f"      issued     : {payload.get('issued_at')}")
    print(f"      expires    : {payload.get('expires_at') or 'never'}")
    lectures = payload.get("lectures", [])
    print(f"      lectures   : {', '.join(l['id'] for l in lectures)} "
          f"({len(lectures)})")

    rc = 0
    exp = payload.get("expires_at")
    if exp:
        today = _dt.date.today()
        end = _dt.date.fromisoformat(exp)
        if today > end:
            print(f"      EXPIRED on {exp} ({(today - end).days} days ago)",
                  file=sys.stderr)
            rc = 1

    if args.fp:
        want = cp_crypto.normalize_fingerprint(args.fp)
        have = payload.get("fp", "")
        if want != have:
            print(f"MISMATCH  licence is bound to {cp_crypto.format_fingerprint(have)}, "
                  f"not {cp_crypto.format_fingerprint(want)}", file=sys.stderr)
            rc = 1
        else:
            print("      device binding: matches")

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
