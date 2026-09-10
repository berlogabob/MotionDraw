import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/camera_strip.dart';

void main() {
  // 3 wide × 2 high:
  //  1 2 3
  //  4 5 6
  final f = Frame(
      bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      width: 3,
      height: 2,
      stride: 3);

  test('orient rotation 0 is identity', () {
    final g = orient(f);
    expect((g.width, g.height), (3, 2));
    expect(g.bytes, [1, 2, 3, 4, 5, 6]);
  });

  test('orient 90° clockwise', () {
    final g = orient(f, rotation: 90);
    expect((g.width, g.height), (2, 3));
    expect(g.bytes, [4, 1, 5, 2, 6, 3]);
  });

  test('orient 270° clockwise', () {
    expect(orient(f, rotation: 270).bytes, [3, 6, 2, 5, 1, 4]);
  });

  test('orient flips', () {
    expect(orient(f, flipH: true).bytes, [3, 2, 1, 6, 5, 4]);
    expect(orient(f, flipV: true).bytes, [4, 5, 6, 1, 2, 3]);
    expect(orient(f, rotation: 180).bytes, [6, 5, 4, 3, 2, 1]);
  });

  test('stripOf averages the band and crops the run', () {
    final g = Gray(Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80, 90]), 3, 3);
    // vertical line at column 1, band 2 → columns 0 and 1
    expect(stripOf(g, vertical: true, at: 1, band: 2), [15, 45, 75]);
    expect(stripOf(g, vertical: true, at: 1, band: 2, start: 1, length: 1),
        [45]);
    // horizontal line at row 2, band 1
    expect(stripOf(g, vertical: false, at: 2, band: 1), [70, 80, 90]);
  });

  test('rgbaOf lifts grey and sets alpha', () {
    final px = rgbaOf(Gray(Uint8List.fromList([0, 255]), 2, 1));
    expect(px, [170, 170, 170, 255, 255, 255, 255, 255]);
  });
}
