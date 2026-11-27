# CoursePack

CoursePack is an offline Android and Windows video-course player. There is no
server or account database: course files are encrypted, and licences are
verified on the device. See the project handoff/specification before adding
product features.

## Current milestone

This repository starts with the Flutter app shell and a GitHub Actions build
pipeline. The app screen is intentionally only a temporary bootstrap; it is
not the activation flow or a playable product yet. There is no demo course or
seed data.

The selected app identity is:

- Student-facing name: **CoursePack**
- Android application ID: **`com.coursepack.app`**

The workflow generates platform runner projects during CI, runs Flutter tests,
and uploads:

- **CoursePack-Android-debug** — a debug APK for pipeline verification only.
  It uses an ephemeral runner debug signing key and is not suitable for
  production distribution or issuing licences against.
- **CoursePack-Windows** — a zip containing the Windows release build output.

Artifacts are available from the run's **Actions → workflow run → Artifacts**
section. They are retained for 14 days. The Android production signing
keystore must be created and stored securely once before any production APK
is distributed; it must never be regenerated after licences are issued.

## Build locally (optional)

Install Flutter with Android and/or Windows desktop support, then run:

```sh
flutter pub get
flutter test
```

The CI workflow generates platform runners on hosted GitHub machines, so no
local Android Studio or Visual Studio installation is needed to verify this
initial milestone.

## Security boundaries

- Never write decrypted video to disk, even temporarily.
- Never commit private signing keys, Android keystores, licences, or `.enc`
  course files.
- Do not distribute the initial debug APK as a production build.
