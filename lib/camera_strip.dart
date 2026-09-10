import 'dart:math';
import 'dart:typed_data';

/// One camera frame's pixel data, platform-agnostic. [pixelStride] and
/// [channelOffset] pick the luminance byte: Y plane = (1, 0); RGBA/BGRA =
/// (4, 1 or 2) (green channel — good enough as a luminance proxy).
class Frame {
  const Frame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.stride,
    this.pixelStride = 1,
    this.channelOffset = 0,
  });
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride; // bytes per row (≠ width * pixelStride on some devices)
  final int pixelStride;
  final int channelOffset;
}

/// Screen-oriented 8-bit luminance. The single source of truth: it is both
/// drawn on screen and analysed, so picture and detection cannot disagree.
class Gray {
  const Gray(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Rotate a sensor frame [rotation] degrees clockwise (0/90/180/270), then
/// mirror horizontally ([flipH]) / vertically ([flipV]) into a [Gray].
Gray orient(Frame f, {int rotation = 0, bool flipH = false, bool flipV = false}) {
  final quarter = ((rotation % 360) ~/ 90) & 3;
  final swap = quarter.isOdd;
  final w = swap ? f.height : f.width;
  final h = swap ? f.width : f.height;
  final out = Uint8List(w * h);
  final src = f.bytes;
  for (var y = 0; y < h; y++) {
    final oy = flipV ? h - 1 - y : y;
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final ox = flipH ? w - 1 - x : x;
      final int sx, sy;
      switch (quarter) {
        case 1:
          sx = oy;
          sy = f.height - 1 - ox;
        case 2:
          sx = f.width - 1 - ox;
          sy = f.height - 1 - oy;
        case 3:
          sx = f.width - 1 - oy;
          sy = ox;
        default:
          sx = ox;
          sy = oy;
      }
      out[row + x] = src[sy * f.stride + sx * f.pixelStride + f.channelOffset];
    }
  }
  return Gray(out, w, h);
}

/// Band-averaged 1-D strip along a line. [vertical] line at column [at]
/// (else row [at]); [band] pixels thick; only indices [start, start+length)
/// along the line are returned, so strip index maps 1:1 onto bins.
Uint8List stripOf(
  Gray g, {
  required bool vertical,
  required int at,
  int band = 10,
  int start = 0,
  int? length,
}) {
  final along = vertical ? g.height : g.width;
  final across = vertical ? g.width : g.height;
  final n = min(length ?? along - start, along - start);
  final b = min(band, across);
  final a0 = (at - b ~/ 2).clamp(0, across - b);
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final p = start + i;
    var sum = 0;
    for (var k = 0; k < b; k++) {
      final x = vertical ? a0 + k : p;
      final y = vertical ? p : a0 + k;
      sum += g.bytes[y * g.width + x];
    }
    out[i] = sum ~/ b;
  }
  return out;
}

/// Display pixels: grey lifted towards white so black ink reads on top.
Uint8List rgbaOf(Gray g, {double gain = 0.35, double lift = 170}) {
  final out = Uint8List(g.width * g.height * 4);
  for (var i = 0, o = 0; i < g.bytes.length; i++, o += 4) {
    final v = (g.bytes[i] * gain + lift).round().clamp(0, 255);
    out[o] = v;
    out[o + 1] = v;
    out[o + 2] = v;
    out[o + 3] = 255;
  }
  return out;
}
