# CoursePack — project brief for a fresh session

Paste the block below into a new chat that has GitHub connected, so the session
starts with the right picture instead of re-deriving it.

---

## Copy this into the new chat

> I'm building **CoursePack**: an Android + Windows app that plays a video
> course I sell to classmates, with no server of any kind. The repo is
> `<your-github-user>/courseapp` — read `README.md`, `docs/FORMAT.md`,
> `docs/UI.md` and `HANDOFF.md` before changing anything.
>
> Already done: the Python toolchain that encrypts the course and issues
> device-bound licences (75 self-tests pass), and the full interface spec.
> Not done: the Flutter app itself — that's the job now.
>
> Build and test in GitHub's cloud with `.github/workflows/build.yml`; my PC
> has only 16 GB free so I can't install Flutter, Android Studio or Visual
> Studio locally. Please drive the build through GitHub Actions and give me
> artifacts to download.
>
> Work in small steps and explain one thing at a time.

---

## What the product is

A course I made, sold to classmates. They install an app, send me a device
code, I send back a signed licence file, and they watch. Video is encrypted at
rest, decrypted only in memory, watermarked with their name, and screen capture
is blocked by the OS. Sharing the app does nothing (no licence = no keys).
Sharing a licence does nothing (bound to their device). It runs with **no
server, no database, no hosting bill**.

Delivery: I encrypt the lectures on my laptop, upload the `.enc` files to one
private Telegram channel, and students import them into the app.

## Hard constraints

- **No servers.** Not optional. Ledger, activation, everything is offline and
  cryptographic. Ed25519 signatures replace an auth API.
- **This machine can't build.** 16 GB free. All compilation happens in GitHub
  Actions; the human only downloads artifacts.
- **Windows 10/11 target.** The app must feel native enough not to embarrass
  itself next to any other player.
- **A virgin app.** No seed data, no demo course, no fake students. First launch
  on any machine shows the device-code screen and nothing else.

## What exists in the repo

| Path | State |
|---|---|
| `tools/cp_crypto.py` | done — the file format, chunked AES-256-GCM, Ed25519, seek-by-chunk |
| `tools/make_keys.py` | done — signing keypair |
| `tools/make_course.py` | done — videos → `.enc` + signed manifest |
| `tools/make_licence.py` | done — one student, one device, signed `.lic` |
| `tools/verify_licence.py` | done — support tool |
| `tools/player_sim.py` | done — reference player, proves the licence gate |
| `tools/self_test.py` | done — 75 assertions, all passing |
| `docs/FORMAT.md` | done — byte-for-byte spec, normative |
| `docs/UI.md` + `mockups/ui.html` | done — layout agreed, awaiting final sign-off |
| `docs/SETUP-WINDOWS.md` | done — but superseded by cloud builds |
| `scripts/*.ps1` | done — local build helpers (unused if building in CI) |
| `.github/workflows/build.yml` | done, never executed yet |
| **Flutter app** | **not started — the actual job** |

There is no `pubspec.yaml` and no `lib/` yet. `flutter create` comes first.

## Locked technical decisions

Do not re-litigate these without asking.

- **Flutter**, one codebase → Android APK + Windows exe. Video via `media_kit`.
- **Chunked AES-256-GCM**, 1 MiB chunks, nonce = `file_nonce[0:8] || uint32_be(i)`.
  Header is 64 bytes, magic `CRS1`. Offsets are arithmetic:
  chunk *i* starts at `64 + i * (chunk_size + 16)`. Full details in
  `docs/FORMAT.md` — it is normative, the Python is the reference.
- **Licences are signed JSON**, verified against an Ed25519 public key compiled
  into the app. Gate order: signature → course id → device fingerprint →
  expiry → clock-rollback check.
- **Device fingerprint** = `SHA256("CoursePack-v1|" + components)`, first 16 hex
  chars, displayed as `A1B2-C3D4-E5F6-7788`. Android: `ANDROID_ID` + app id +
  signing cert + build fingerprint. Windows: `MachineGuid` + volume serial +
  CPU id.
- **Playback never touches disk in plaintext.** Run a `127.0.0.1` HTTP server
  with Range support backed by on-demand chunk decryption; `media_kit` plays
  that URL with a random per-session path token and a required header.
- **Capture guard** at OS level: `FLAG_SECURE` (Android),
  `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` (Windows).
- **Watermark** drawn above the video: name · licence id · phone, ~30 %
  opacity, drifting. Not in the file.
- **Read `.enc` in place**, never copy it into app storage.

## The job, in order

1. `flutter create --platforms=android,windows --org com.<id> coursepack`,
   then verify the CI workflow produces both artifacts from the empty skeleton.
   **Ship this before writing features** — proving the pipeline works while
   nothing can be blamed on our code is worth more than a day of coding.
2. `lib/crypto/` — Dart port of `cp_crypto.py`. Port the Python self-tests to
   `flutter test`. Bytes must match the Python output exactly; add a test that
   decrypts a fixture produced by `make_course.py`.
3. `lib/licence/` — parse, verify, fingerprint, expiry, clock-rollback.
   Activation screen (`docs/UI.md` §2).
4. `lib/import/` — file picker, in-place paths, SAF persisted permissions,
   sha256 verify against the signed manifest.
5. `lib/stream/` — the localhost Range server.
6. `lib/player/` — the PowerPoint-style layout, scrubber, fullscreen, fit/fill.
7. Watermark + capture guard platform channels.
8. Package: APK for Android, zipped folder for Windows (never a bare `.exe`).

## Rules the next session must not break

- Never write decrypted video to disk, temp or cache.
- Never ship the private signing key; it belongs on my laptop and a USB stick.
- Never commit `android/key.properties`, `*.jks`, `secrets/`, `licenses/`,
  `keys/ed25519_private.pem`, or any `.enc` file.
- The Android keystore is created once and must never be regenerated — it is
  part of every student's fingerprint. Yesterday's build and today's must share
  it or every licence breaks.
- No mock data in the app. Test fixtures live in `test/` only.

## Still open, needs my answer

- Application ID (`com.____.coursepack`) and the app name students see.
- Rail down the side, or filmstrip along the bottom, as the phone default.
- Do I want burned-in captions? (`.vtt` per lecture.)
