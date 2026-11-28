#!/usr/bin/env python3
"""
Encrypt a folder of lecture videos into CoursePack .enc files, then emit a
signed manifest.

    python tools/make_course.py \
        --input ~/course/raw \
        --out   ~/course/dist \
        --secrets secrets \
        --keydir keys \
        --title "Statistics 201"

Outputs
-------
  course/dist/L01.enc ...        uploaded to Telegram (safe to leak)
  course/dist/manifest.json      uploaded to Telegram (safe to leak)
  course/dist/manifest.sig       uploaded to Telegram (safe to leak)
  secrets/course_keys.json       NEVER uploaded. Your keyring for licences.

The manifest carries no keys. Losing it costs nothing but a re-run.
The keys file is the only thing that must stay private besides your
signing key.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto  # noqa: E402

VIDEO_EXTS = {".mp4", ".mkv", ".mov", ".m4v", ".webm", ".avi", ".ts", ".mts"}
TELEGRAM_WARN_BYTES = 1900 * 1024 * 1024   # keep clear of the 2 GB document cap


def natural_key(name: str):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} TB"


def probe_duration(path: str) -> float | None:
    exe = shutil.which("ffprobe")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=120, check=True,
        ).stdout.strip()
        return round(float(out), 2)
    except Exception:
        return None


def reencode(src: str, tmpdir: str, crf: int, max_height: int) -> str:
    """Shrink before encrypting. Optional — needs ffmpeg on PATH."""
    exe = shutil.which("ffmpeg")
    if not exe:
        raise cp_crypto.CoursePackError("--reencode needs ffmpeg on PATH")
    dst = os.path.join(tmpdir, "re.mp4")
    scale = f"scale=-2:'min({max_height},ih)'"
    cmd = [
        exe, "-y", "-v", "error", "-i", src,
        "-vf", scale,
        "-c:v", "libx265", "-crf", str(crf), "-preset", "medium",
        "-tag:v", "hvc1",
        "-c:a", "aac", "-b:a", "96k", "-ac", "2",
        "-movflags", "+faststart",
        dst,
    ]
    print(f"    re-encoding (crf {crf}, ≤{max_height}p)…")
    subprocess.run(cmd, check=True, timeout=60 * 60 * 6)
    return dst


def main() -> int:
    ap = argparse.ArgumentParser(description="Encrypt lecture videos into .enc files.")
    ap.add_argument("--input", required=True, help="folder of source videos (or one file)")
    ap.add_argument("--out", default="dist", help="where .enc + manifest go (default: dist)")
    ap.add_argument("--secrets", default="secrets", help="where course_keys.json goes")
    ap.add_argument("--keydir", default="keys", help="dir holding the signing keypair")
    ap.add_argument("--title", default="My Course", help="course title")
    ap.add_argument("--chunk-log2", type=int, default=cp_crypto.DEFAULT_CHUNK_LOG2,
                    help="log2 of chunk size in bytes (default 20 = 1 MiB)")
    ap.add_argument("--reencode", action="store_true",
                    help="shrink with ffmpeg before encrypting (needs ffmpeg)")
    ap.add_argument("--crf", type=int, default=28, help="x265 CRF for --reencode (default 28)")
    ap.add_argument("--max-height", type=int, default=1080, help="cap resolution (default 1080)")
    args = ap.parse_args()

    # ---- collect inputs -------------------------------------------------
    if os.path.isdir(args.input):
        files = [
            os.path.join(args.input, n)
            for n in sorted(os.listdir(args.input), key=natural_key)
            if os.path.splitext(n)[1].lower() in VIDEO_EXTS
        ]
    elif os.path.isfile(args.input):
        files = [args.input]
    else:
        print(f"error: no such path: {args.input}", file=sys.stderr)
        return 2

    if not files:
        print(f"error: no video files found in {args.input}", file=sys.stderr)
        print(f"       looked for: {', '.join(sorted(VIDEO_EXTS))}", file=sys.stderr)
        return 2

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.secrets, exist_ok=True)

    priv = cp_crypto.load_private_key(args.keydir)
    course_id = os.urandom(8).hex().upper()
    created = _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()

    print(f"course {course_id} — {len(files)} lecture(s) -> {args.out}")
    print()

    manifest_lectures = []
    key_lectures = []
    total_pt = 0
    total_ct = 0
    warnings = []

    for idx, src in enumerate(files, start=1):
        lid = f"L{idx:02d}"
        base = os.path.splitext(os.path.basename(src))[0]
        label = re.sub(r"^[0-9]+[-_. )]*", "", base) or base
        enc_path = os.path.join(args.out, f"{lid}.enc")
        src_size = os.path.getsize(src)
        print(f"  {lid}  {base}  ({human(src_size)})")

        work_dir = None
        to_encrypt = src
        try:
            if args.reencode:
                work_dir = tempfile.mkdtemp(prefix="cp-")
                to_encrypt = reencode(src, work_dir, args.crf, args.max_height)
                print(f"    re-encoded -> {human(os.path.getsize(to_encrypt))}")

            key = cp_crypto.new_content_key()
            duration = probe_duration(to_encrypt)

            with open(to_encrypt, "rb") as fin, open(enc_path, "wb") as fout:
                cp_crypto.encrypt_stream(
                    fin, fout, key, chunk_log2=args.chunk_log2
                )
        finally:
            if work_dir:
                shutil.rmtree(work_dir, ignore_errors=True)

        enc_size = os.path.getsize(enc_path)
        digest = cp_crypto.sha256_file(enc_path)
        with open(enc_path, "rb") as f:
            hdr = cp_crypto.read_header(f)
        pt_size = hdr.plaintext_size

        if enc_size > TELEGRAM_WARN_BYTES:
            warnings.append(
                f"{lid} is {human(enc_size)} — over Telegram's 2 GB per-file cap. "
                f"Split it or re-run with --reencode."
            )

        manifest_lectures.append({
            "id": lid,
            "title": label,
            "duration_s": duration,
            "file": f"{lid}.enc",
            "size": enc_size,
            "plaintext_size": pt_size,
            "chunk_log2": args.chunk_log2,
            "sha256": digest,
        })
        key_lectures.append({
            "id": lid,
            "title": label,
            "file": f"{lid}.enc",
            "duration_s": duration,
            "key": cp_crypto.b64e(key),
        })
        total_pt += pt_size
        total_ct += enc_size
        print(f"       -> {human(enc_size)}  sha256 {digest[:16]}…")

    manifest = {
        "v": cp_crypto.FORMAT_VERSION,
        "course_id": course_id,
        "title": args.title,
        "created_at": created,
        "lectures": manifest_lectures,
    }
    sig = cp_crypto.sign(priv, manifest)

    manifest_path = os.path.join(args.out, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    with open(os.path.join(args.out, "manifest.sig"), "w", encoding="ascii") as f:
        f.write(sig + "\n")

    keys_payload = {
        "v": cp_crypto.FORMAT_VERSION,
        "course_id": course_id,
        "title": args.title,
        "created_at": created,
        "lectures": key_lectures,
    }
    keys_path = os.path.join(args.secrets, "course_keys.json")
    with open(keys_path, "w", encoding="utf-8") as f:
        json.dump(keys_payload, f, indent=2)
    os.chmod(keys_path, 0o600)

    print()
    print(f"done. {human(total_pt)} plaintext -> {human(total_ct)} encrypted")
    print(f"  ship  : {args.out}/  ({len(files)} .enc + manifest.json + manifest.sig)")
    print(f"  secret: {keys_path}   <-- never upload this")

    if warnings:
        print()
        for w in warnings:
            print(f"  WARNING: {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
