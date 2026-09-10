import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/scale_mapper.dart';

void main() {
  test('pentatonic minor from A3', () {
    expect(binToMidi(0), 57); // A3
    expect(binToMidi(1), 60); // C4
    expect(binToMidi(4), 67); // G4
    expect(binToMidi(5), 69); // A4 — octave wrap
    expect(binToMidi(10), 81); // A5
  });

  test('chromatic wraps at 12', () {
    final chromatic = scales['chromatic']!;
    expect(binToMidi(11, root: 60, intervals: chromatic), 71);
    expect(binToMidi(12, root: 60, intervals: chromatic), 72);
  });

  test('major scale intervals', () {
    final major = scales['major']!;
    expect(
      List.generate(8, (i) => binToMidi(i, root: 60, intervals: major)),
      [60, 62, 64, 65, 67, 69, 71, 72],
    );
  });

  test('midiToFreq', () {
    expect(midiToFreq(69), 440);
    expect(midiToFreq(81), closeTo(880, 1e-9));
    expect(midiToFreq(57), closeTo(220, 1e-9));
  });

  test('tickMs', () {
    expect(tickMs(120, 4), 500);
    expect(tickMs(120, 8), 250);
    expect(tickMs(90, 16), 167);
  });
}
