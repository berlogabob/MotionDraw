= MotionDraw
<motiondraw>
A camera instrument. A guide line sits over the live camera image inside
a white passepartout frame with a square grid. Whatever crosses the line
plays a note. Position along the line picks the pitch, quantised to a
scale, and the grid cell where it happened flashes black.

Live web build: https:/\/berlogabob.github.io/MotionDraw/ (tap once to
start audio, allow the camera). Runs natively on macOS, iOS and Android.

== Playing
<playing>
+ Point the camera at something that moves (people, traffic, rain on a
  window) or at a still scene with edges and spots (sunlight through
  blinds, a bookshelf).
+ Drag inside the frame to move the line. Double-tap flips it between
  vertical and horizontal. The line always snaps to a grid line.
+ Pick a mode:
  - #strong[DYNAMIC] --- the line stays put; anything that moves across
    it plays. Low notes are at the bottom (vertical line) or left
    (horizontal line); `LOW` flips that.
  - #strong[STATIC] --- press `PLAY` and the line sweeps across the
    frame as a playhead; every edge or bright spot it crosses plays.
    `SWEEP` sets the time for one pass. The sweep direction follows
    `LOW`.
+ Optional tempo:
  - #strong[TEMPO : QUANT] --- detected notes wait for the next grid
    tick and play together, so a scene falls onto a beat.
  - #strong[TEMPO : SEQ] --- each detection is appended to a looping
    step sequence played one note per tick. Empty steps fill first, then
    the oldest step is overwritten, so the phrase keeps following the
    scene. `LEN` sets the loop length; `CLEAR` empties it.
  - `BPM` taps through 80, 100, 120, 140, 160; drag it sideways for any
    value between 40 and 240. `DIV` is the tick: 1/4, 1/8, 1/16.
  - The square at the end of the TEMPO line is the click: it fills on
    every tick and grows on the downbeat (each quarter note). Notes only
    ever sound on those fills.
+ Open the ≡ button at the frame's top-right for scale, root, synth,
  sensitivity, camera and flips. The camera keeps running underneath.

Tuning tip: if nothing fires, raise `SENS` (drag the track right). If
the wall texture itself fires, lower it. `LAST` shows the strength of
the last trigger, so you can see how far above or below threshold a
scene sits.

== Controls
<controls>
Three caption lines under the frame are the performance controls; tap a
row to change it. Everything else lives in the settings sheet behind ≡.

#figure(
  align(center)[#table(
    columns: (auto, auto, 1fr),
    align: left + top,
    table.header([Where], [Row], [Values],),
    table.hline(),
    [screen], [MODE], [dynamic / static],
    [], [PLAY], [stopped / playing (static)],
    [], [SWEEP], [4s / 8s / 16s per pass (static)],
    [], [LINE], [vertical / horizontal],
    [], [LOW], [bottom / top, or left / right: pitch direction, also
    sweep direction],
    [], [TEMPO], [off / quant / seq],
    [], [BPM], [tap 80…160, drag 40…240 (tempo on)],
    [], [DIV], [1/4, 1/8, 1/16 (tempo on)],
    [], [LEN], [8 / 16 / 32 steps (seq)],
    [], [CLEAR], [empty the sequence (seq)],
    [settings], [SCALE], [penta minor, penta major, minor, major, blues,
    chromatic],
    [], [ROOT], [C … B (octave 3)],
    [], [SYNTH], [sine, triangle, saw, square, supersaw],
    [], [SENS], [0.25 LOW … 4.00 MAX; tap cycles presets, drag the track
    below it for any value],
    [], [CAMERA], [cycle devices: front / back, USB cameras, browser
    inputs],
    [], [FLIP H], [mirror the picture and the detection together],
    [], [FLIP V], [same, vertically],
    [], [LAST], [intensity of the last trigger],
    [], [FULLSCREEN], [web only],
    [], [CLOSE], [back to the picture],
  )]
  , kind: table
  )

Selfie cameras (laptop, phone front) start with `FLIP H` on so the
picture behaves like a mirror.

== Design
<design>
Monochrome: white ground, black ink, one typeface (IBM Plex Mono). The
picture is the camera's luminance lifted towards paper. The passepartout
is whatever the image does not cover, so it adapts to every camera
aspect and screen. The grid is anchored at the image centre with 12
cells across the short side on every device; the dead centre of the
camera is always a grid crossing.

== How it works
<how-it-works>
What you see is what is analysed. Each platform delivers raw frames; the
app never shows a platform camera preview.

```
platform frame ─ orient(rotation, flipH, flipV) ─▶ Gray (screen-oriented luminance)
                                                    ├─▶ drawn as the picture
                                                    └─▶ stripOf(line, band 10 px)
                                                          └─▶ detector ─▶ bins ─▶ notes
```

- `lib/feeds.dart` --- camera sources. Mobile uses the `camera` plugin's
  image stream (no preview widget), macOS keeps the `camera_macos` view
  at one invisible pixel because it only streams frames while its
  texture is painted, web samples a detached `<video>` through a canvas
  (`lib/web_feed.dart`).
- `lib/camera_strip.dart` --- `orient` rotates and flips into `Gray`\;
  `stripOf` averages a thin band along the line into a 1-D strip cropped
  to the whole centred cells; `rgbaOf` makes the display pixels.
- `lib/canvas_screen.dart` --- geometry (`Geom`: cell size, bins,
  snapping, fit), the frame painter, caption rows, settings sheet, tempo
  clock.
- `lib/motion_detector.dart` --- two detectors over the strip.
  `MotionDetector` (dynamic) diffs consecutive strips per bin with an
  EMA, Schmitt trigger, two-frame confirmation, refractory period and
  rejection of global motion (camera shake). `StaticDetector` (static)
  scores each bin by the contrast of its brightest quarter against the
  strip median and fires on the rising edge, with no global rejection,
  so a row of spots is a chord.
- `lib/sequence.dart` --- the looping step sequence for `TEMPO : SEQ`.
- `lib/scale_mapper.dart` --- scales, bin → MIDI note, tick length.
- `lib/sampler.dart` --- SoLoud waveform voices, one source per
  (instrument, pitch). Pitch is set with the waveform frequency, because
  SoLoud's synth derives its phase step from the voice sample rate and
  play speed cannot retune it. Sample-based instruments can plug in
  behind the same cache later.

Bins along the line are the whole centred grid cells: 12 on the short
axis, 16 on the long axis of a 4:3 camera. Pitch = root + scale interval
of the bin, octaves stacking upward.

== Run and build
<run-and-build>
```
flutter pub get
flutter run -d macos          # or ios / android / chrome
flutter test                  # detectors, geometry, sequence, widget tests
flutter build web --release   # output in build/web
```

Platform notes:

- #strong[macOS] --- the first launch asks for camera permission. When
  started from a terminal the prompt is attributed to the terminal app;
  allow it once.
- #strong[Android / iOS] --- the camera permission is requested on first
  launch. Back camera is the default; switch with `CAMERA`.
- #strong[Web] --- browsers need a gesture before audio, hence the start
  screen. The camera permission prompt follows. `FULLSCREEN` is in the
  settings sheet. Audio runs single-threaded on plain static hosting;
  heavy UI work can crackle.

Deployment: every push to `main` builds the web app and publishes it to
GitHub Pages through `.github/workflows/pages.yml`.

== Documentation PDF
<documentation-pdf>
`docs/MotionDraw.pdf` is generated from this README (pandoc → Typst).
Enable the hook once with `git config core.hooksPath tools/hooks`\;
every commit that touches README.md then regenerates
`docs/readme-body.typ` and the PDF and stages them. By hand:
`tools/readme_pdf.sh`.

== Repository
<repository>
```
lib/           app code (see How it works)
test/          unit tests for orient/strip, detectors, scale, sequence; widget tests for the UI
web/           Flutter web scaffold with the SoLoud loader scripts
assets/fonts/  IBM Plex Mono (OFL)
docs/          Typst template and generated PDF of this README
tools/         readme_pdf.sh and the pre-commit hook
android/ ios/ macos/   platform runners
```

== License
<license>
MIT. IBM Plex Mono is bundled under the SIL Open Font License.
