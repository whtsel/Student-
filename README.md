# CoursePack

CoursePack is an offline Android and Windows video-course player. Course files
are encrypted; licences are verified locally. There is no server or account
database. The normative format and UI specifications are in `docs/`.

## Project state

- Reference Python tools and format: included in `tools/` and `docs/`.
- Flutter shell and GitHub Actions builds: in place.
- Dart crypto port: underway in `lib/crypto/`, with byte-for-byte Python
  fixture tests.
- Activation, import, and playback UI: not implemented yet.
- No demo course or fake student data is shipped.

Selected application identity:

- Student-facing name: **CoursePack**
- Android application ID: **`com.coursepack.app`**

## Cloud builds

The `Build CoursePack` GitHub Actions workflow compiles both targets and runs
Flutter tests. The Android output is currently a **debug APK for pipeline
verification only**; it uses an ephemeral debug signing key and must not be
used for production or licence issuance. The Windows artifact is a zip of the
release build folder. Artifacts are listed at the bottom of each workflow run
and retained for 14 days.

The Android production keystore must be created and stored securely once
before any production APK is distributed. Never regenerate it after licences
have been issued.

## Tests

With Flutter installed:

```sh
flutter pub get
flutter test
```

The Python reference self-tests can be run with `cryptography` installed:

```sh
python tools/self_test.py
```

## Security boundaries

- Never write decrypted video to disk, even temporarily.
- Never commit private signing keys, Android keystores, licences, `secrets/`,
  or course `.enc` files. Synthetic `.enc` fixtures belong only in `test/`.
- Never ship the private Ed25519 signing key or course decryption keys.
