# CoursePack wire format (v1)

Normative spec. `tools/cp_crypto.py` is the reference implementation; this
document is what the Dart port is written against. If the two ever disagree,
the Python implementation and `tools/self_test.py` win, and this doc gets fixed.

All integers are **big-endian**. All base64 is **standard, padded**.

---

## 1. `.enc` lecture file

```
┌──────────────────────────────────────────────────────────────┐
│ HEADER (64 bytes)                                            │
├──────────────────────────────────────────────────────────────┤
│ chunk 0 ciphertext   (chunk_size + 16 bytes)                 │
│ chunk 1 ciphertext   (chunk_size + 16 bytes)                 │
│ ...                                                          │
│ chunk N-1 ciphertext (last_chunk_len + 16 bytes)             │
└──────────────────────────────────────────────────────────────┘
```

### 1.1 Header

| Offset | Size | Field | Value |
|-------:|-----:|-------|-------|
| 0 | 4 | magic | ASCII `CRS1` |
| 4 | 1 | version | `1` |
| 5 | 1 | flags | `0` (reserved) |
| 6 | 2 | chunk_log2 | uint16, 12–24 inclusive; chunk size = `1 << chunk_log2` |
| 8 | 16 | file_nonce | random, unique per file |
| 24 | 8 | plaintext_size | uint64, size of the original video in bytes |
| 32 | 16 | file_id | random, unique per file |
| 48 | 16 | reserved | **all zero** |

Reject the file if the magic is wrong, the version isn't 1, `chunk_log2` is out
of range, or any reserved byte is non-zero. Reject early — a hostile or
corrupt file should never reach the decoder.

### 1.2 Chunk nonce

12 bytes, derived per chunk:

```
nonce = file_nonce[0:8] || uint32_be(chunk_index)
```

### 1.3 Chunk encryption

```
ciphertext_i = AES-256-GCM(key = lecture_key, nonce = nonce_i,
                           plaintext = plaintext_chunk_i, aad = empty)
```

The GCM tag (16 bytes) is appended to each chunk. Every chunk except the last
is exactly `chunk_size` plaintext bytes; the last is
`plaintext_size - (N-1) * chunk_size` where `N = ceil(plaintext_size / chunk_size)`.

### 1.4 Offsets (this is what makes seeking cheap)

Because every non-final chunk is a fixed size, no index is needed:

```
chunk_count       = ceil(plaintext_size / chunk_size)      (0 if empty)
chunk_i_offset    = 64 + i * (chunk_size + 16)             absolute file byte
chunk_i_len       = plaintext_len_i + 16
total_file_size   = 64 + plaintext_size + chunk_count * 16
```

To read plaintext bytes `[start, end)`:

```
first = start / chunk_size
last  = (end - 1) / chunk_size
for i in first..last:
    plain_i = decrypt(chunk i)
    emit plain_i[max(start, i*chunk_size) - i*chunk_size :
                 min(end,   i*chunk_size + len(plain_i)) - i*chunk_size]
```

**Do not decrypt the whole file to seek.** A 2 GB lecture must seek in a few
milliseconds.

---

## 2. `manifest.json` + `manifest.sig`

Distributed alongside the `.enc` files. Contains **no keys** — it is safe to
publish, leak, or re-download from Telegram.

```json
{
  "v": 1,
  "course_id": "88797A3E7D16D86C",
  "title": "Statistics 201",
  "created_at": "2026-11-26T23:12:10+00:00",
  "lectures": [
    {
      "id": "L01",
      "title": "Welcome and course outline",
      "duration_s": 812.5,
      "file": "L01.enc",
      "size": 3051520,
      "plaintext_size": 3048768,
      "chunk_log2": 20,
      "sha256": "<hex of the whole .enc file>"
    }
  ]
}
```

`manifest.sig` is the base64 Ed25519 signature over the **canonical JSON** of
the manifest.

**Canonical JSON** = keys sorted lexicographically at every level, no
whitespace, no trailing newline, UTF-8, non-ASCII characters left unescaped.
In Dart: build a `SplayTreeMap` recursively, then `jsonEncode`. Verify your
implementation against these bytes — the signature depends on it:

```
canonical({"b":1,"a":"é"}) == {"a":"é","b":1}
```

The app must verify this signature before trusting any lecture metadata.
A tampered manifest can't grant access (keys aren't in it) but could redirect
the app at the wrong file or lie about hashes.

`sha256` is computed over the ciphertext, so it is checked without the
lecture key. Verify at import time — that's how a corrupted Telegram download
is caught before the student sits down to watch.

---

## 3. `<student>.lic`

```json
{
  "payload": {
    "v": 1,
    "course_id": "88797A3E7D16D86C",
    "course_title": "Statistics 201",
    "lic_id": "LIC-879C88",
    "name": "Ama Mensah",
    "phone": "0240000000",
    "fp": "A1B2C3D4E5F67788",
    "issued_at": "2026-11-26T23:12:10+00:00",
    "expires_at": "2027-06-30",
    "lectures": [
      {
        "id": "L01",
        "title": "Welcome and course outline",
        "file": "L01.enc",
        "duration_s": 812.5,
        "key": "<base64, 32 raw bytes>"
      }
    ]
  },
  "sig": "<base64 Ed25519 over canonical JSON of payload>"
}
```

`expires_at` may be `null` for no expiry. `duration_s` may be `null` if
`ffprobe` was unavailable when the course was built.

### App startup gate — in this order

1. Read the file, parse JSON. Fail → "Licence file is not readable."
2. Verify `sig` against the **public key compiled into the app**. Fail → "This
   licence file has been modified and is not valid." (Also catches a licence
   signed by someone else's keypair.)
3. Compare `payload.course_id` to the manifest's `course_id`. Mismatch →
   "This licence is for a different course."
4. Compute **this device's fingerprint** (§4) and compare to `payload.fp`.
   Mismatch → "This licence was issued to a different device." Show the
   device code so they can request a licence for this one.
5. Check `expires_at` against the current date. Fail → "This licence expired on
   <date>." Reject if the system clock is earlier than the last recorded
   wall-clock time (anti clock-rollback), persisted on first launch.
6. Only then show the lecture list, and only the lecture ids present in
   `payload.lectures`.

Everything except step 2 is cosmetic in the sense that it can be bypassed by
patching the app. Step 2 is the one that actually holds: without your private
key a new licence cannot be produced.

---

## 4. Device fingerprint

The app computes, once, at first launch, and displays it as
`A1B2-C3D4-E5F6-7788` (16 uppercase hex characters, dash-grouped in 4s).
The seller types it into `make_licence.py --fp`. The licence stores the
normalised 16 chars.

```
fp = SHA256(salt_bytes || platform_component_string)
fp16 = hex(fp).upper()[0:16]
salt_bytes = "CoursePack-v1|" as UTF-8
```

`platform_component_string` — join the available parts with `|`, skipping any
that are unavailable:

| Platform | Components |
|---|---|
| Android | `android:` + `ANDROID_ID` (Settings.Secure) · `app-id:` + applicationId · `cert:` + SHA-256 of the signing certificate · `build:` + `Build.FINGERPRINT` |
| Windows | `win:` + `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` · `vol:` + volume serial number of the system drive · `cpu:` + processor identifier |

Example Android component string:

```
android:9774d56d682e549c|app-id:com.yourname.coursepack|cert:3a7f…|build:google/sdk_gphone64/…
```

Notes and honest limitations:

- Changing device, factory reset, or (on Windows) reinstalling the OS changes
  the fingerprint. That is a support ticket, not a bug. Keep it to the
  non-volatile parts listed above and it survives normal app updates.
- `ANDROID_ID` is already scoped per app-signing-key on Android 8+, so it
  cannot be correlated with other apps. Good.
- A determined user can patch the app to accept any fingerprint. This deters
  classmates, not analysts. Accepted.

---

## 5. What the app must NOT do

- Must not write decrypted video to disk, cache, or temp storage.
- Must not require the `.enc` file to live inside app storage — read in place
  (SAF persisted URI on Android, absolute path on Windows). Otherwise the
  student stores the course twice.
- Must not embed the course keys anywhere except in signed licences.
- Must not embed the private signing key. Ever. There is no reason for it to
  exist outside your machine and your offline backup.
