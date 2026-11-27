# Interface spec

Companion to `mockups/ui.html` (open it — it's clickable).

## Shape of the thing

Landscape, two zones, PowerPoint-editor layout:

```
┌───────────────────────────────────────────────────────────────┐
│ ▣ Statistics 201        [▭][⛶][≡][⛶]      active until … ┌AM┐ │  top bar
│   Module 2 · 12 lectures                                   └──┘ │
├───────────────┬───────────────────────────────────────────────┤
│ LECTURES 9/12 │                                               │
│ ── Module 1 ─ │        ┌───────────────────────────┐          │
│ ▢ L01 13:32 ✓ │        │                           │          │
│ ▢ L02 21:04 ✓ │        │   the video frame         │          │  ← 16:9 stage
│ ── Module 2 ─ │        │   (letterboxed, centred)  │          │
│ ▣ L03 34:18 ● │        │                           │          │
│ ▢ L04 28:55   │        └───────────────────────────┘          │
│ ▢ L05 19:41   │        ──────●─────── 12:47/34:18  ⛶          │
│ ── Module 3 ─ │                                        │
│ 🔒 L06 26:02  │  Now playing: L03 · Measures…  [Mark complete]│
└───────────────┴───────────────────────────────────────────────┘
     268px                        flexible
```

The rail is the slide panel from PowerPoint; the stage is the canvas. It works
because a 12-lecture course is a list you want to *see*, not hunt through — and
because locked lectures sitting greyed out right next to unlocked ones is a
quieter sales pitch than a paywall page.

## Zones

| Zone | Content | Notes |
|---|---|---|
| Top bar | course title, module/size line, view toggles, licence chip, student chip | the licence chip is the only "DRM-looking" thing on screen — keep it small and calm |
| Rail | module headers + lecture cards | 62 px slide-style thumbnail, title, duration, lock or progress |
| Stage | 16:9 rectangle, black letterbox | never stretches; longest edge fits |
| In-frame controls | scrubber with chapter ticks, transport, speed, CC, fullscreen | sits over the video, hidden after 3 s of no pointer movement while playing |
| Transport strip | now playing, Mark complete, Notes, Next lecture | the "what do I do next" row |
| Watermark | student name · licence id · phone, ~30 % opacity, drifts over ~34 s | above the video, below the controls, `IgnorePointer` |

## Orientation and sizing

- **Android**: lock to landscape. `android:screenOrientation="sensorLandscape"`
  in the manifest, plus `SystemChrome.setPreferredOrientations`.
- **Windows**: default 1280×720, minimum 960×540, remember last size and
  position. Fullscreen on F11 or ⛶.
- **Breakpoint 860 px**: rail moves under the stage and becomes a horizontal
  filmstrip (that's the toggle in the mockup — see if you prefer it as the
  default on small screens).

## Fit and fullscreen

Two separate buttons, because they answer different questions:

- **Fit** — scale the video up to the largest size that fits the screen with
  the aspect ratio intact (letterboxed). Default.
- **Fill** — crop the edges to cover the screen. For a slide recording this
  cuts content, so it's available but never automatic.

Fullscreen is a window/system-UI state, not a new screen: on Android hide
the status and navigation bars via `SystemChrome.setEnabledSystemUIMode`, on
Windows `window_manager` → `setFullScreen(true)`. The rail and top bar slide
out; Esc or ⛶ returns to the same lecture at the same timestamp.

## Keyboard (Windows)

`Space` play/pause · `←/→` ±5 s · `J/L` ±10 s · `↑/↓` volume · `F` or `F11`
fullscreen · `N/P` next/previous lecture · `Esc` exit fullscreen ·
`0–9` seek to 10 % steps.

## States the UI must handle without looking broken

| State | Rail | Stage |
|---|---|---|
| No licence | visible, all locked, no durations | activation view (§2 of the mockup) |
| Licence for another device | visible, all locked | activation view, with "this licence belongs to another device" and the current code |
| Expired | visible, all locked | renewal date, device code, no playback |
| Manifest signature bad | empty | "course files have been altered — re-download from the channel" |
| Lecture not imported | card shows "not imported" | import CTA for that lecture only |
| Importing | card shows a spinner + % | unchanged |
| Checksum failed | card shows a warning, never "ready" | "this file is damaged, download L04 again" |
| Locked by licence | padlock thumbnail, muted | shake on click, no navigation |

## Thumbnails — a small addition to the build tool

The rail needs a picture per lecture. Add to `make_course.py`, when `ffmpeg` is
present:

```
ffmpeg -ss <10% of duration> -i in.mp4 -frames:v 1 -vf scale=124:-2 -q:v 6 L01.jpg
```

- stored in `dist/L01.jpg`, referenced from the manifest as `"thumb": "L01.jpg"`
- they are **not** secret — they sit next to the `.enc` files and leak nothing
  worth having (three stills of a slide you're selling anyway are a teaser)
- 124 px wide is enough for a 62 px slot at 2× density, and keeps the whole
  set under a megabyte

## Flutter mapping

| Mockup | Flutter |
|---|---|
| `.topbar` | `Container` + `Row`, `SafeArea` on Android |
| `.rail` | `ListView.builder` (vertical) / `ListView.builder(scrollDirection: horizontal)` for the strip |
| `.stage` | `AspectRatio(16/9)` in a `Center`, inside `Stack` |
| letterbox | `FittedBox(fit: BoxFit.contain)` around the video surface |
| fullscreen | `window_manager` (Windows) / `SystemChrome` (Android) — not a `Navigator` push |
| `.wm` | `AnimationController` + `AnimatedPositioned`, wrapped in `IgnorePointer` |
| capture guard | `MethodChannel` → `FLAG_SECURE` (Kotlin) / `SetWindowDisplayAffinity` (Win32) |
| video surface | `media_kit` `Video` widget on top of the local Range server |
| fonts | system only — no webfonts, the app is fully offline |

## Open questions

1. **Rail or filmstrip as the default?** Toggle the ▭ button in the mockup and
   tell me which feels right for your course.
2. **"PowerPoint" as layout, or as authoring?** If you meant you want to *build
   slides* in the app with videos embedded per slide, that's a different and
   much larger product — say so now, not after the player is written.
3. **Captions?** For a course this is usually worth more than anti-piracy
   polish. A `.vtt` per lecture, played as a subtitle track, is a day's work.
