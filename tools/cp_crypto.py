"""
CoursePack crypto core — reference implementation.

This module is the single source of truth for the .enc file format, the
manifest format and the licence format. The Flutter app must match it
byte for byte. Any format change here MUST be mirrored in
docs/FORMAT.md and in the Dart port.

Design summary
--------------
* Lecture video is encrypted with AES-256-GCM in fixed-size chunks.
* Each chunk gets its own GCM nonce, so the player can seek to any
  timestamp by decrypting only the chunks it needs. This is what makes
  scrubbing survive encryption.
* Every non-final ciphertext chunk is exactly chunk_size + 16 bytes, so
  ciphertext offsets are computable arithmetically. That is what makes
  HTTP Range serving possible.
* Integrity: the GCM tag per chunk detects tampering or corruption.
* Authenticity of metadata and permissions: Ed25519 signature over a
  canonical JSON licence, verified with a public key baked into the app.
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import struct
from dataclasses import dataclass
from typing import BinaryIO, Callable, Iterable, Optional

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag, InvalidSignature

# --------------------------------------------------------------------------
# Constants — mirrored in Dart
# --------------------------------------------------------------------------

MAGIC = b"CRS1"
FORMAT_VERSION = 1
HEADER_SIZE = 64
TAG_SIZE = 16
DEFAULT_CHUNK_LOG2 = 20          # 1 MiB chunks
MIN_CHUNK_LOG2 = 12              # 4 KiB floor
MAX_CHUNK_LOG2 = 24              # 16 MiB ceiling
KEY_SIZE = 32


class CoursePackError(Exception):
    """Raised for any structural or integrity failure."""


# --------------------------------------------------------------------------
# Header
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Header:
    version: int
    chunk_log2: int
    file_nonce: bytes            # 16 bytes
    plaintext_size: int
    file_id: bytes               # 16 bytes

    @property
    def chunk_size(self) -> int:
        return 1 << self.chunk_log2

    @property
    def chunk_count(self) -> int:
        if self.plaintext_size == 0:
            return 0
        return math.ceil(self.plaintext_size / self.chunk_size)

    @property
    def ciphertext_chunk_size(self) -> int:
        return self.chunk_size + TAG_SIZE

    @property
    def total_ciphertext_size(self) -> int:
        return HEADER_SIZE + self.plaintext_size + self.chunk_count * TAG_SIZE


def build_header(
    file_nonce: bytes,
    plaintext_size: int,
    file_id: bytes,
    chunk_log2: int = DEFAULT_CHUNK_LOG2,
) -> bytes:
    if len(file_nonce) != 16:
        raise CoursePackError("file_nonce must be 16 bytes")
    if len(file_id) != 16:
        raise CoursePackError("file_id must be 16 bytes")
    if not (MIN_CHUNK_LOG2 <= chunk_log2 <= MAX_CHUNK_LOG2):
        raise CoursePackError(f"chunk_log2 out of range: {chunk_log2}")
    if plaintext_size < 0:
        raise CoursePackError("negative plaintext size")

    h = bytearray(HEADER_SIZE)
    h[0:4] = MAGIC
    h[4] = FORMAT_VERSION
    h[5] = 0                                    # reserved / flags
    struct.pack_into(">H", h, 6, chunk_log2)
    h[8:24] = file_nonce
    struct.pack_into(">Q", h, 24, plaintext_size)
    h[32:48] = file_id
    # 48..63 reserved, must be zero
    return bytes(h)


def parse_header(buf: bytes) -> Header:
    if len(buf) < HEADER_SIZE:
        raise CoursePackError("file shorter than header")
    if buf[0:4] != MAGIC:
        raise CoursePackError("bad magic — not a CoursePack file")
    version = buf[4]
    if version != FORMAT_VERSION:
        raise CoursePackError(f"unsupported format version {version}")
    chunk_log2 = struct.unpack_from(">H", buf, 6)[0]
    if not (MIN_CHUNK_LOG2 <= chunk_log2 <= MAX_CHUNK_LOG2):
        raise CoursePackError(f"chunk_log2 out of range: {chunk_log2}")
    if any(buf[48:64]):
        raise CoursePackError("reserved header bytes must be zero")
    plaintext_size = struct.unpack_from(">Q", buf, 24)[0]
    return Header(
        version=version,
        chunk_log2=chunk_log2,
        file_nonce=bytes(buf[8:24]),
        plaintext_size=plaintext_size,
        file_id=bytes(buf[32:48]),
    )


def read_header(fobj: BinaryIO) -> Header:
    pos = fobj.tell()
    fobj.seek(0)
    raw = fobj.read(HEADER_SIZE)
    fobj.seek(pos)
    return parse_header(raw)


# --------------------------------------------------------------------------
# Chunk helpers
# --------------------------------------------------------------------------

def chunk_nonce(file_nonce: bytes, index: int) -> bytes:
    """12-byte GCM nonce: first 8 bytes of file_nonce || uint32 index (BE)."""
    if index < 0 or index > 0xFFFFFFFF:
        raise CoursePackError("chunk index out of range")
    return file_nonce[:8] + struct.pack(">I", index)


def chunk_ciphertext_offset(index: int, chunk_size: int) -> int:
    """Absolute byte offset of ciphertext chunk `index` in the file."""
    return HEADER_SIZE + index * (chunk_size + TAG_SIZE)


def plaintext_chunk_len(header: Header, index: int) -> int:
    if index < 0 or index >= header.chunk_count:
        raise CoursePackError("chunk index out of range")
    if index == header.chunk_count - 1:
        consumed = index * header.chunk_size
        return header.plaintext_size - consumed
    return header.chunk_size


# --------------------------------------------------------------------------
# Encryption / decryption
# --------------------------------------------------------------------------

Progress = Optional[Callable[[int, int], None]]


def new_content_key() -> bytes:
    return os.urandom(KEY_SIZE)


def encrypt_stream(
    src: BinaryIO,
    dst: BinaryIO,
    key: bytes,
    chunk_log2: int = DEFAULT_CHUNK_LOG2,
    file_nonce: Optional[bytes] = None,
    file_id: Optional[bytes] = None,
    progress: Progress = None,
) -> Header:
    if len(key) != KEY_SIZE:
        raise CoursePackError("content key must be 32 bytes")
    file_nonce = file_nonce or os.urandom(16)
    file_id = file_id or os.urandom(16)

    src.seek(0, os.SEEK_END)
    plaintext_size = src.tell()
    src.seek(0)

    header = Header(
        version=FORMAT_VERSION,
        chunk_log2=chunk_log2,
        file_nonce=file_nonce,
        plaintext_size=plaintext_size,
        file_id=file_id,
    )
    dst.write(build_header(file_nonce, plaintext_size, file_id, chunk_log2))

    aead = AESGCM(key)
    cs = header.chunk_size
    written = 0
    for i in range(header.chunk_count):
        block = src.read(cs)
        if not block:
            raise CoursePackError("source truncated while reading")
        dst.write(aead.encrypt(chunk_nonce(file_nonce, i), block, None))
        written += len(block)
        if progress:
            progress(written, plaintext_size)

    if written != plaintext_size:
        raise CoursePackError("source size changed during encryption")
    dst.flush()
    return header


def decrypt_chunk(fobj: BinaryIO, header: Header, key: bytes, index: int) -> bytes:
    cs = header.chunk_size
    fobj.seek(chunk_ciphertext_offset(index, cs))
    want = plaintext_chunk_len(header, index) + TAG_SIZE
    blob = fobj.read(want)
    if len(blob) != want:
        raise CoursePackError(f"truncated ciphertext at chunk {index}")
    try:
        return AESGCM(key).decrypt(chunk_nonce(header.file_nonce, index), blob, None)
    except InvalidTag as exc:
        raise CoursePackError(
            f"integrity failure at chunk {index} — file corrupt or tampered"
        ) from exc


def decrypt_range(
    fobj: BinaryIO,
    header: Header,
    key: bytes,
    start: int,
    end: int,
) -> bytes:
    """
    Decrypt plaintext byte range [start, end) by touching only the chunks
    that overlap it. This is the function the HTTP Range server in the app
    is modelled on.
    """
    if start < 0 or end < start or end > header.plaintext_size:
        raise CoursePackError(f"bad range [{start}, {end})")
    if start == end:
        return b""

    cs = header.chunk_size
    first = start // cs
    last = (end - 1) // cs

    out = bytearray()
    for i in range(first, last + 1):
        plain = decrypt_chunk(fobj, header, key, i)
        chunk_start = i * cs
        lo = max(start, chunk_start) - chunk_start
        hi = min(end, chunk_start + len(plain)) - chunk_start
        out += plain[lo:hi]
    return bytes(out)


def decrypt_to_stream(
    src: BinaryIO,
    dst: BinaryIO,
    key: bytes,
    progress: Progress = None,
) -> Header:
    header = read_header(src)
    done = 0
    for i in range(header.chunk_count):
        dst.write(decrypt_chunk(src, header, key, i))
        done += plaintext_chunk_len(header, i)
        if progress:
            progress(done, header.plaintext_size)
    dst.flush()
    return header


def verify_file(fobj: BinaryIO, key: bytes, progress: Progress = None) -> Header:
    """Full integrity pass. Raises CoursePackError on any bad chunk."""
    header = read_header(fobj)
    done = 0
    for i in range(header.chunk_count):
        decrypt_chunk(fobj, header, key, i)
        done += plaintext_chunk_len(header, i)
        if progress:
            progress(done, header.plaintext_size)
    return header


def sha256_file(path: str, bufsize: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(bufsize)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


# --------------------------------------------------------------------------
# Canonical JSON + Ed25519
# --------------------------------------------------------------------------

def canonical_json(obj) -> bytes:
    """Deterministic serialisation. Dart port: sorted keys, no spaces."""
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def b64e(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text)


def generate_keypair():
    priv = Ed25519PrivateKey.generate()
    return priv, priv.public_key()


def save_keypair(priv: Ed25519PrivateKey, keydir: str) -> tuple[str, str]:
    os.makedirs(keydir, exist_ok=True)
    priv_path = os.path.join(keydir, "ed25519_private.pem")
    pub_path = os.path.join(keydir, "ed25519_public.pem")
    b64_path = os.path.join(keydir, "ed25519_public.b64")

    if os.path.exists(priv_path):
        raise CoursePackError(
            f"{priv_path} already exists — refusing to overwrite your signing key"
        )

    pem = priv.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with open(priv_path, "wb") as f:
        f.write(pem)
    os.chmod(priv_path, 0o600)

    pub_pem = priv.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    with open(pub_path, "wb") as f:
        f.write(pub_pem)

    raw_pub = priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    with open(b64_path, "w", encoding="ascii") as f:
        f.write(b64e(raw_pub) + "\n")

    return priv_path, pub_path


def load_private_key(keydir: str) -> Ed25519PrivateKey:
    path = os.path.join(keydir, "ed25519_private.pem")
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def load_public_key(keydir: str) -> Ed25519PublicKey:
    path = os.path.join(keydir, "ed25519_public.pem")
    with open(path, "rb") as f:
        return serialization.load_pem_public_key(f.read())


def sign(priv: Ed25519PrivateKey, payload_obj) -> str:
    return b64e(priv.sign(canonical_json(payload_obj)))


def verify_signature(pub: Ed25519PublicKey, payload_obj, sig_b64: str) -> bool:
    try:
        pub.verify(b64d(sig_b64), canonical_json(payload_obj))
        return True
    except (InvalidSignature, ValueError):
        return False


# --------------------------------------------------------------------------
# Device fingerprint (client computes; seller only stores/compares)
# --------------------------------------------------------------------------

def normalize_fingerprint(text: str) -> str:
    """
    Accepts 'A1B2-C3D4-E5F6-7788', 'a1b2c3d4e5f67788' etc.
    Returns 16 uppercase hex chars — the form stored in the licence.
    """
    cleaned = "".join(ch for ch in (text or "").upper() if ch in "0123456789ABCDEF")
    if len(cleaned) < 16:
        raise CoursePackError(
            f"fingerprint must contain at least 16 hex characters, got {len(cleaned)}"
        )
    return cleaned[:16]


def format_fingerprint(fp16: str) -> str:
    term = normalize_fingerprint(fp16)
    return "-".join(term[i:i + 4] for i in range(0, 16, 4))
