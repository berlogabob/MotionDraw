# MotionDraw

A camera instrument. A guide line sits over the live camera image inside a
white passepartout frame with a square grid. Anything that crosses the line
plays a note: position along the line picks the pitch, quantised to a scale.
The cell where it happened flashes black.

## Modes

- **Dynamic** — camera and line are fixed; moving objects that cross the line
  trigger notes.
- **Static** — the line becomes a playhead that sweeps across the frame and
  plays the still scene: every edge it crosses is a note.

## Controls

Everything is in the caption under the frame. Tap a row to change it.

| Row     | Values                                  |
| ------- | --------------------------------------- |
| SCALE   | pentatonic minor/major, minor, major, blues, chromatic |
| ROOT    | C … B                                   |
| LINE    | vertical / horizontal                   |
| LOW     | bottom/top or left/right — pitch direction, also sweep direction |
| MODE    | dynamic / static                        |
| PLAY    | stopped / playing (static only)         |
| SWEEP   | 4s / 8s / 16s per pass (static only)    |
| SENS    | sensitivity, set with the slider inside the frame |
| LAST    | intensity of the last trigger           |

Drag inside the frame to move the line. Double-tap flips its orientation.

## Run

```
flutter pub get
flutter run -d macos    # or ios / android
flutter test
```

Runs on macOS (`camera_macos`), iOS and Android (`camera`). Audio via
`flutter_soloud`.

## How it works

`camera_strip.dart` averages a thin band of pixels along the line into a 1-D
strip. `motion_detector.dart` diffs consecutive strips per bin with an EMA,
Schmitt trigger and refractory period. `scale_mapper.dart` turns a bin into a
MIDI note. `sampler.dart` plays one waveform voice per pitch.

## License

MIT
