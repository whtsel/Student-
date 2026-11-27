#!/usr/bin/env python3
"""
Generate your signing keypair. Run this ONCE, ever.

    python tools/make_keys.py --keydir keys

Then:
  * back up keys/ed25519_private.pem somewhere safe (USB stick, password
    manager attachment). If you lose it you cannot issue any more
    licences and every licence you already issued becomes unverifiable.
  * ship keys/ed25519_public.b64 inside the app.
  * NEVER put the private key in the app, in Telegram, in git, or in a
    Google Drive folder.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description="Create the CoursePack signing keypair.")
    ap.add_argument("--keydir", default="keys", help="output directory (default: keys)")
    args = ap.parse_args()

    try:
        priv_path, pub_path = cp_crypto.save_keypair(
            cp_crypto.generate_keypair()[0], args.keydir
        )
    except cp_crypto.CoursePackError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("Delete the old key only if you accept losing the ability to "
              "verify previously issued licences.", file=sys.stderr)
        return 1

    b64_path = os.path.join(args.keydir, "ed25519_public.b64")
    with open(b64_path, encoding="ascii") as f:
        pub_b64 = f.read().strip()

    print("keypair created")
    print(f"  private : {priv_path}   <-- BACK THIS UP, THEN GET IT OFF THIS MACHINE")
    print(f"  public  : {pub_path}")
    print(f"  public b64 (paste into the app): {pub_b64}")
    print()
    print("Public key fingerprint (for your records, not security):")
    print(f"  {pub_b64[:16]}...")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
