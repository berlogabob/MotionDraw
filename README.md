# MotionDraw

A camera instrument. A guide line sits over the live camera image inside a
white passepartout frame with a square grid. Anything that crosses the line
plays a note: position along the line picks the pitch, quantised to a scale.
The cell where it happened flashes black.

What you see is what is analysed: the app draws the very frame it detects
on, so picture, grid, line and detection share one coordinate system on every
platform. The whole camera image is always visible; the passepartout adapts
around it. The grid is anchored at the image centre with 12 cells across the
short side.

## Modes

- **Dynamic** — camera and line are fixed; moving objects that cross the line
  trigger notes.
- **Static** — the line becomes a playhead that sweeps across the frame and
  plays the still scene: every edge it crosses is a note.

## Controls

Two caption lines under the frame are the performance controls; tap a row to
change it. Everything else is behind the ≡ button at the frame's top-right,
which opens a settings sheet inside the frame window.

| Where    | Row    | Values                                  |
| -------- | ------ | --------------------------------------- |
| screen   | MODE   | dynamic / static                        |
|          | PLAY   | stopped / playing (static only)         |
|          | SWEEP  | 4s / 8s / 16s per pass (static only)    |
|          | LINE   | vertical / horizontal                   |
|          | LOW    | bottom/top or left/right — pitch direction, also sweep direction |
|          | TEMPO  | off / quant / seq — quant: notes wait for the next tick and play together; seq: detections fill a looping step sequence, one note per tick |
|          | BPM    | tap cycles 80…160, drag sideways for any value (tempo on) |
|          | DIV    | 1/4, 1/8, 1/16 (tempo on)               |
|          | LEN    | 8 / 16 / 32 steps (seq)                 |
|          | CLEAR  | empty the sequence (seq)                |
| settings | SCALE  | penta minor/major, minor, major, blues, chromatic |
|          | ROOT   | C … B                                   |
|          | SYNTH  | sine, triangle, saw, square, supersaw   |
|          | SENS   | 0.25 LOW … 4 MAX; tap cycles presets, drag the track for fine control |
|          | CAMERA | cycle devices: front/rear, USB, browser inputs |
|          | FLIP H | mirror picture and detection together   |
|          | FLIP V |                                         |
|          | LAST   | intensity of the last trigger           |
|          | FULLSCREEN | web only                            |

Drag inside the frame to move the line. Double-tap flips its orientation.

## Run

Web build: https://berlogabob.github.io/MotionDraw/ (tap once to start audio,
allow the camera).

```
flutter pub get
flutter run -d macos    # or ios / android
flutter test
```

Runs on macOS (`camera_macos`), iOS and Android (`camera`). Audio via
`flutter_soloud`.

## How it works

`feeds.dart` delivers raw frames from the platform camera (no platform
preview is shown). `camera_strip.dart` orients and flips a frame into a
screen-space grey buffer, draws it, and averages a thin band of pixels along
the line into a 1-D strip. `motion_detector.dart` diffs consecutive strips per
bin with an EMA, Schmitt trigger and refractory period. `scale_mapper.dart`
turns a bin into a MIDI note. `sampler.dart` plays one waveform voice per
(instrument, pitch).

## License

MIT
