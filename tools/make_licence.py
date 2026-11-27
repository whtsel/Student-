#!/usr/bin/env python3
"""
Issue a licence for one student, bound to one device.

Typical session:

  1. Student installs the app. It shows a device code, e.g.
         A1B2-C3D4-E5F6-7788
     They WhatsApp it to you along with the name on their payment.

  2. You run:
         python tools/make_licence.py \
             --name "Ama Mensah" --phone 0240000000 \
             --fp A1B2-C3D4-E5F6-7788 \
             --secrets secrets/course_keys.json --keydir keys \
             --expires 2027-06-30

  3. Send them licenses/ama-mensah.lic on WhatsApp. Done.

The resulting file is signed with your private key. The student cannot
edit the name, expiry, unlocked lectures, or device binding — any edit
invalidates the signature and the app refuses to run.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import secrets
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto  # noqa: E402


def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "student"


def load_keys(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        payload = json.load(f)
    if payload.get("v") != cp_crypto.FORMAT_VERSION:
        raise cp_crypto.CoursePackError(
            f"course_keys.json has unsupported version {payload.get('v')}"
        )
    return payload


def parse_lectures(raw: str, available: list[str]) -> list[str]:
    raw = (raw or "all").strip()
    if raw.lower() == "all":
        return list(available)
    wanted = [t.strip().upper() for t in raw.split(",") if t.strip()]
    missing = [w for w in wanted if w not in available]
    if missing:
        raise cp_crypto.CoursePackError(
            f"unknown lecture id(s): {', '.join(missing)}. "
            f"available: {', '.join(available)}"
        )
    return wanted


def main() -> int:
    ap = argparse.ArgumentParser(description="Issue a device-bound student licence.")
    ap.add_argument("--name", required=True, help="student name (shown in the watermark)")
    ap.add_argument("--fp", required=True, help="device code shown by the app")
    ap.add_argument("--phone", default="", help="optional phone for the watermark")
    ap.add_argument("--secrets", default="secrets/course_keys.json",
                    help="course_keys.json from make_course.py")
    ap.add_argument("--keydir", default="keys", help="dir holding the signing keypair")
    ap.add_argument("--expires", default="", help="YYYY-MM-DD (omit for no expiry)")
    ap.add_argument("--lectures", default="all", help="'all' or L01,L03")
    ap.add_argument("--out", default="licenses", help="output dir (default: licenses)")
    ap.add_argument("--lic-id", default="", help="override licence id")
    ap.add_argument("--force", action="store_true", help="overwrite an existing file")
    args = ap.parse_args()

    try:
        keys = load_keys(args.secrets)
        fp = cp_crypto.normalize_fingerprint(args.fp)
    except (cp_crypto.CoursePackError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    available = [l["id"] for l in keys["lectures"]]
    try:
        chosen = parse_lectures(args.lectures, available)
    except cp_crypto.CoursePackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.expires:
        try:
            _dt.date.fromisoformat(args.expires)
        except ValueError:
            print(f"error: --expires must be YYYY-MM-DD, got {args.expires!r}",
                  file=sys.stderr)
            return 2

    lic_id = (args.lic_id or f"LIC-{secrets.token_hex(3).upper()}").strip()
    now = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()

    payload = {
        "v": cp_crypto.FORMAT_VERSION,
        "course_id": keys["course_id"],
        "course_title": keys.get("title", ""),
        "lic_id": lic_id,
        "name": args.name.strip(),
        "phone": args.phone.strip(),
        "fp": fp,
        "issued_at": now,
        "expires_at": args.expires or None,
        "lectures": [
            {
                "id": l["id"],
                "title": l["title"],
                "file": l["file"],
                "duration_s": l.get("duration_s"),
                "key": l["key"],
            }
            for l in keys["lectures"] if l["id"] in chosen
        ],
    }

    priv = cp_crypto.load_private_key(args.keydir)
    sig = cp_crypto.sign(priv, payload)

    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, f"{slug(args.name)}.lic")
    if os.path.exists(out_path) and not args.force:
        print(f"error: {out_path} exists. Use --force to overwrite, or pass "
              f"--out with a different directory.", file=sys.stderr)
        return 1

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"payload": payload, "sig": sig}, f, indent=2, ensure_ascii=False)
    os.chmod(out_path, 0o444)

    print(f"licence issued: {out_path}")
    print(f"  student    : {payload['name']}")
    print(f"  licence id : {lic_id}")
    print(f"  device     : {cp_crypto.format_fingerprint(fp)}")
    print(f"  expires    : {payload['expires_at'] or 'never'}")
    print(f"  lectures   : {', '.join(chosen)}  ({len(chosen)}/{len(available)})")
    print()
    print("Reminder: this file only works on that one device. Send it as-is.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
