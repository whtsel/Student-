# CoursePack — Licence Generator (Android)

The seller-side tool for **CoursePack**, an offline video-course platform with
no server. This app issues and checks the device-bound, Ed25519-signed `.lic`
files that unlock a student's course. It runs entirely on-device against the
seller's signing key and `course_keys.json` — no network, no database.

It is the Android equivalent of the Python tool `tools/make_licence.py`, built
on the same cryptographic core, and it produces **byte-for-byte identical**
licences (verified by a cross-language test against a real Python fixture).

## What it does

- **Issue** — enter a student's name, phone, device code and (optional)
  expiry, pick the lectures to unlock, and sign a `.lic` file. The app writes
  the file wherever you choose via the system file picker; nothing is copied
  into app storage.
- **Check** — open any `.lic` to confirm it is intact, unexpired and bound to
  the expected device code.
- **Keys** — load your Ed25519 private key (PKCS#8 `.pem` or a raw seed) and
  the `course_keys.json` produced by `make_course.py`.

## Project state

| Piece | State |
|---|---|
| Python reference toolchain (`tools/`) | done — `tools/self_test.py` passes |
| Dart crypto port (`lib/crypto/`) | done — byte-for-byte Python fixture tests |
| Device-identity plugin (`packages/coursepack_device_identity`) | done (student player) |
| **Licence generator app (`lib/licenser/`)** | **this deliverable** |
| File picker/saver plugin (`packages/coursepack_file_io`) | done (Android) |
| GitHub Actions build (`.github/workflows/build.yml`) | Android APK |

## Build (in the cloud)

The owner's machine cannot install Flutter or the Android SDK, so the app is
compiled by GitHub Actions. Push or run the **“Build CoursePack Licence
Generator”** workflow manually and download the APK from the run's artifacts.

- Without keystore secrets the workflow produces a **debug APK** (pipeline
  check). For a release APK, add the repository secrets documented at the top
  of `.github/workflows/build.yml` (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
  `KEY_PASSWORD`, `KEY_ALIAS`).

## Tests

```sh
flutter pub get
flutter test
python tools/self_test.py   # needs the `cryptography` package
```

`test/licenser/licence_model_test.dart` signs and verifies against
`test/fixtures/python_reference.lic`, a licence produced by the real Python
toolchain. Because Ed25519 is deterministic, the Dart signature must equal the
Python one exactly — that is the cross-language guarantee.

## Security boundaries

- The private Ed25519 signing key never leaves your device and is never
  committed. Back it up offline; losing it means no new licences can be issued.
- `course_keys.json` (lecture decryption keys) is private — never upload or
  commit it.
- Licences are bound to a device fingerprint, so sharing a `.lic` file does
  nothing on another device.
- Never commit `*.jks`, `*.keystore`, `secrets/`, `licenses/`, real `.lic`
  files, or course `.enc` files. Synthetic test fixtures live only in
  `test/fixtures/`.
