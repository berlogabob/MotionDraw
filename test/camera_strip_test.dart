import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/camera_strip.dart';

void main() {
  test('coverCrop: 4:3 image into a wide box crops height only', () {
    final c = coverCrop(640, 480, 1490, 935);
    expect(c.fx, closeTo(1, 1e-9));
    expect(c.ox, closeTo(0, 1e-9));
    expect(c.fy, closeTo(935 / (480 * 1490 / 640), 1e-9));
    expect(c.oy, closeTo((1 - c.fy) / 2, 1e-9));
  });

  test('coverCrop: same aspect shows everything', () {
    final c = coverCrop(4, 3, 8, 6);
    expect((c.ox, c.fx, c.oy, c.fy), (0.0, 1.0, 0.0, 1.0));
  });
}
