import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/motion_detector.dart';

const len = 150; // 10 px per bin at 15 bins

Uint8List quiet() => Uint8List(len);

/// Strip with a bright blob covering one bin.
Uint8List blobAt(int bin, {int value = 255}) {
  final s = Uint8List(len);
  for (var i = bin * 10; i < (bin + 1) * 10; i++) {
    s[i] = value;
  }
  return s;
}

void main() {
  test('blob crossing a bin fires that bin once', () {
    final d = MotionDetector();
    expect(d.process(quiet(), 0), isEmpty); // primes prev frame
    expect(d.process(blobAt(7), 33), isEmpty); // frame 1 of confirmation
    final events = d.process(blobAt(7, value: 0), 66); // still changing
    expect(events.map((e) => e.bin), [7]);
    expect(events.single.intensity, greaterThan(0));
  });

  test('no retrigger while activity stays high (Schmitt)', () {
    final d = MotionDetector();
    d.process(quiet(), 0);
    // Alternate blob on/off so diff stays high every frame.
    var fired = 0;
    for (var f = 1; f < 20; f++) {
      fired += d
          .process(blobAt(7, value: f.isEven ? 255 : 0), f * 33)
          .length;
    }
    expect(fired, 1);
  });

  test('re-fires after settling below low threshold', () {
    final d = MotionDetector(refractoryMs: 100);
    d.process(quiet(), 0);
    d.process(blobAt(7), 33);
    expect(d.process(blobAt(7, value: 0), 66), hasLength(1));
    // Settle: identical frames drive EMA to 0, re-arming the bin.
    for (var f = 3; f < 10; f++) {
      expect(d.process(quiet(), f * 33), isEmpty);
    }
    d.process(blobAt(7), 400);
    expect(d.process(blobAt(7, value: 0), 433), hasLength(1));
  });

  test('global flash is rejected', () {
    final d = MotionDetector();
    d.process(quiet(), 0);
    final lit = Uint8List.fromList(List.filled(len, 255));
    expect(d.process(lit, 33), isEmpty);
    expect(d.process(quiet(), 66), isEmpty);
    expect(d.process(lit, 99), isEmpty);
  });

  test('two separate blobs fire two bins (polyphony)', () {
    final d = MotionDetector();
    d.process(quiet(), 0);
    Uint8List two(int v) {
      final s = Uint8List(len);
      for (var i = 20; i < 30; i++) {
        s[i] = v; // bin 2
      }
      for (var i = 120; i < 130; i++) {
        s[i] = v; // bin 12
      }
      return s;
    }

    d.process(two(255), 33);
    expect(d.process(two(0), 66).map((e) => e.bin), [2, 12]);
  });
}
