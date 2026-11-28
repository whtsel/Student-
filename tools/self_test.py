#!/usr/bin/env python3
"""
End-to-end proof that the format works before a single line of Flutter is
written.

    python tools/self_test.py

Covers: size arithmetic, round-trip, seek accuracy, tamper detection,
truncation detection, wrong-key rejection, and licence signature forgery.
Exits non-zero on the first failure.
"""

from __future__ import annotations

import io
import json
import os
import random
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cp_crypto as cp  # noqa: E402

PASS, FAIL = 0, 0


def check(label):
    global PASS, FAIL
    def inner(cond, detail=""):
        global PASS, FAIL
        if cond:
            PASS += 1
            print(f"  PASS  {label}")
        else:
            FAIL += 1
            print(f"  FAIL  {label}  {detail}")
    return inner


def expect_raises(label, exc_types, fn):
    global PASS, FAIL
    try:
        fn()
    except exc_types:
        PASS += 1
        print(f"  PASS  {label}")
        return
    except Exception as exc:                      # noqa: BLE001
        FAIL += 1
        print(f"  FAIL  {label}  (raised {type(exc).__name__}: {exc})")
        return
    FAIL += 1
    print(f"  FAIL  {label}  (did not raise)")


def roundtrip_case(size: int, chunk_log2: int) -> None:
    print(f"\n[{size} bytes @ chunk 2^{chunk_log2}]")
    rnd = random.Random(size + chunk_log2)
    plaintext = bytes(rnd.getrandbits(8) for _ in range(min(size, 1 << 16)))
    if size > len(plaintext):                     # cheap expansion to full size
        plaintext = (plaintext * (size // max(len(plaintext), 1) + 1))[:size]
    key = cp.new_content_key()

    enc = io.BytesIO()
    header = cp.encrypt_stream(io.BytesIO(plaintext), enc, key, chunk_log2=chunk_log2)
    enc.seek(0)
    blob = enc.getvalue()

    ok = check("ciphertext size matches formula")
    ok(len(blob) == header.total_ciphertext_size,
       f"{len(blob)} != {header.total_ciphertext_size}")

    ok = check("chunk_count correct")
    expected_chunks = 0 if size == 0 else -(-size // (1 << chunk_log2))
    ok(header.chunk_count == expected_chunks,
       f"{header.chunk_count} != {expected_chunks}")

    ok = check("header parses back identically")
    enc.seek(0)
    h2 = cp.read_header(enc)
    ok(h2 == header, f"{h2} != {header}")

    ok = check("full decrypt is byte-identical")
    out = io.BytesIO()
    enc.seek(0)
    cp.decrypt_to_stream(enc, out, key)
    ok(out.getvalue() == plaintext, "plaintext mismatch")

    if size:
        ok = check("verify_file passes on intact file")
        try:
            enc.seek(0)
            cp.verify_file(enc, key)
            ok(True)
        except cp.CoursePackError as exc:
            ok(False, str(exc))

        # seek correctness — every range must equal the plaintext slice
        cs = 1 << chunk_log2
        probes = [
            (0, size),
            (0, min(1, size)),
            (max(0, size - 1), size),
            (size // 3, min(size, size // 3 + 10 * cs)),
            (max(0, cs - 5), min(size, cs + 5)),
            (max(0, 2 * cs), min(size, 2 * cs + 1)),
        ]
        good = True
        detail = ""
        for start, end in probes:
            if not (0 <= start <= end <= size):
                continue
            enc.seek(0)
            got = cp.decrypt_range(enc, header, key, start, end)
            if got != plaintext[start:end]:
                good = False
                detail = f"range [{start},{end})"
                break
        ok = check(f"range/seek decryption exact ({len(probes)} probes)")
        ok(good, detail)

    # ---- tamper -------------------------------------------------------
    if size > 0:
        tampered = bytearray(blob)
        target = cp.chunk_ciphertext_offset(header.chunk_count // 2, 1 << chunk_log2) + 3
        tampered[target] ^= 0x01
        bad = io.BytesIO(bytes(tampered))

        ok = check("tampered chunk rejected by verify_file")
        def run_verify():
            bad.seek(0)
            cp.verify_file(bad, key)
        global PASS, FAIL
        try:
            run_verify()
            ok(False, "no exception raised")
        except cp.CoursePackError:
            ok(True)

        ok = check("GCM tag rejects tampered chunk directly")
        try:
            cp.decrypt_chunk(bad, header, key, header.chunk_count // 2)
            ok(False, "no exception raised")
        except cp.CoursePackError:
            ok(True)

        ok = check("wrong key rejected")
        try:
            cp.decrypt_chunk(io.BytesIO(blob), header, cp.new_content_key(), 0)
            ok(False, "no exception raised")
        except cp.CoursePackError:
            ok(True)

        ok = check("truncated file rejected")
        try:
            trunc = io.BytesIO(blob[: len(blob) - 40])
            cp.decrypt_chunk(trunc, header, key, header.chunk_count - 1)
            ok(False, "no exception raised")
        except cp.CoursePackError:
            ok(True)


def header_cases() -> None:
    print("\n[header validation]")
    key = cp.new_content_key()
    enc = io.BytesIO()
    cp.encrypt_stream(io.BytesIO(b"hello world"), enc, key)
    blob = bytearray(enc.getvalue())

    expect_raises("rejects bad magic",
                  cp.CoursePackError,
                  lambda: cp.parse_header(b"XXXX" + bytes(blob[4:])))
    expect_raises("rejects future version",
                  cp.CoursePackError,
                  lambda: cp.parse_header(bytes(blob[:4]) + b"\x09" + bytes(blob[5:])))
    expect_raises("rejects absurd chunk size",
                  cp.CoursePackError,
                  lambda: cp.parse_header(bytes(blob[:6]) + b"\x00\x02" + bytes(blob[8:])))
    expect_raises("rejects short buffer",
                  cp.CoursePackError,
                  lambda: cp.parse_header(bytes(blob[:10])))


def licence_cases(tmp: str) -> None:
    print("\n[licence signing]")
    keydir = os.path.join(tmp, "keys")
    cp.save_keypair(cp.generate_keypair()[0], keydir)
    priv = cp.load_private_key(keydir)
    pub = cp.load_public_key(keydir)

    payload = {
        "v": 1, "course_id": "AABBCCDD", "lic_id": "LIC-TEST",
        "name": "Ama Mensah", "phone": "0240000000",
        "fp": cp.normalize_fingerprint("a1b2-c3d4-e5f6-7788"),
        "issued_at": "2026-11-26T00:00:00+00:00", "expires_at": "2027-06-30",
        "lectures": [{"id": "L01", "title": "Intro", "file": "L01.enc",
                      "duration_s": 100, "key": cp.b64e(cp.new_content_key())}],
    }
    sig = cp.sign(priv, payload)

    ok = check("valid signature accepted")
    ok(cp.verify_signature(pub, payload, sig))

    edited_name = json.loads(json.dumps(payload))
    edited_name["name"] = "Someone Else"
    ok = check("edited name rejected")
    ok(not cp.verify_signature(pub, edited_name, sig))

    edited_exp = json.loads(json.dumps(payload))
    edited_exp["expires_at"] = "2099-12-31"
    ok = check("extended expiry rejected")
    ok(not cp.verify_signature(pub, edited_exp, sig))

    edited_fp = json.loads(json.dumps(payload))
    edited_fp["fp"] = "FFFFFFFFFFFFFFFF"
    ok = check("rebound device rejected")
    ok(not cp.verify_signature(pub, edited_fp, sig))

    ok = check("garbage signature rejected")
    ok(not cp.verify_signature(pub, payload, cp.b64e(os.urandom(64))))

    ok = check("fingerprint normalisation")
    variants = ["A1B2-C3D4-E5F6-7788", "a1b2c3d4e5f67788",
                "a1b2 c3d4 e5f6 7788", "A1B2C3D4E5F67788"]
    ok(all(cp.normalize_fingerprint(v) == "A1B2C3D4E5F67788" for v in variants))

    expect_raises("fails on a really bad fingerprint",
                  cp.CoursePackError,
                  lambda: cp.normalize_fingerprint("xyz"))


def main() -> int:
    print("CoursePack self-test")
    print("=" * 56)

    roundtrip_case(0, 16)
    roundtrip_case(1, 16)
    roundtrip_case(65536, 16)                    # exactly one chunk
    roundtrip_case(131072, 16)                   # exactly two chunks
    roundtrip_case(cp.HEADER_SIZE, 16)
    roundtrip_case(5_000_003, 16)                # many chunks, ragged tail
    roundtrip_case(2_000_000, 20)                # 1 MiB chunks, real-ish size

    header_cases()

    tmp = tempfile.mkdtemp(prefix="cp-test-")
    try:
        licence_cases(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    print("=" * 56)
    print(f"{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
