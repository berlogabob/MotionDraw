import 'dart:math';
import 'dart:typed_data';

/// One camera frame's pixel data, platform-agnostic. [pixelStride] and
/// [channelOffset] pick the luminance byte: Y plane = (1, 0); ARGB = (4, 2)
/// (green channel — good enough as a luminance proxy for motion diffing).
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

/// Where the detection line lives in *image* coordinates, plus whether the
/// strip must be reversed to match on-screen direction.
class ImageLine {
  const ImageLine(this.vertical, this.pos, this.reversed);
  final bool vertical;
  final double pos; // 0..1 across the perpendicular axis
  final bool reversed;

  /// Account for a mirrored preview (front cameras, macOS default): flip
  /// across the image's vertical axis.
  ImageLine mirroredX() => vertical
      ? ImageLine(true, 1 - pos, reversed)
      : ImageLine(false, pos, !reversed);
}

/// Camera frames arrive in sensor orientation; the preview is rotated by
/// [rotationDegrees] (quarter turns, clockwise) to reach screen space. Map the
/// screen-space line back into image space.
ImageLine screenToImageLine({
  required bool screenVertical,
  required double screenPos,
  required int rotationDegrees,
}) {
  switch (rotationDegrees % 360) {
    case 90:
      return screenVertical
          ? ImageLine(false, 1 - screenPos, false)
          : ImageLine(true, screenPos, true);
    case 180:
      return ImageLine(screenVertical, 1 - screenPos, true);
    case 270:
      return screenVertical
          ? ImageLine(false, screenPos, true)
          : ImageLine(true, 1 - screenPos, false);
    default:
      return ImageLine(screenVertical, screenPos, false);
  }
}

/// Average a [band]-pixel-thick strip of the frame down to a 1-D grayscale
/// line along the detection line.
Uint8List extractStrip(Frame f, ImageLine line, {int band = 10}) {
  final Uint8List strip;
  if (line.vertical) {
    final x0 = (line.pos * f.width - band / 2).round().clamp(0, f.width - band);
    strip = Uint8List(f.height);
    for (var row = 0; row < f.height; row++) {
      var sum = 0;
      final base = row * f.stride + x0 * f.pixelStride + f.channelOffset;
      for (var i = 0; i < band; i++) {
        sum += f.bytes[base + i * f.pixelStride];
      }
      strip[row] = sum ~/ band;
    }
  } else {
    final y0 =
        (line.pos * f.height - band / 2).round().clamp(0, f.height - band);
    strip = Uint8List(f.width);
    for (var col = 0; col < f.width; col++) {
      var sum = 0;
      final base = col * f.pixelStride + f.channelOffset;
      for (var r = 0; r < band; r++) {
        sum += f.bytes[(y0 + r) * f.stride + base];
      }
      strip[col] = sum ~/ band;
    }
  }
  if (line.reversed) {
    return Uint8List.fromList(strip.reversed.toList());
  }
  return strip;
}

/// After BoxFit.cover of an [imgW]x[imgH] image into a [boxW]x[boxH] box,
/// the visible part of each image axis as (offset, fraction) in 0..1.
({double ox, double fx, double oy, double fy}) coverCrop(
    double imgW, double imgH, double boxW, double boxH) {
  final scale = max(boxW / imgW, boxH / imgH);
  final fx = boxW / (imgW * scale);
  final fy = boxH / (imgH * scale);
  return (ox: (1 - fx) / 2, fx: fx, oy: (1 - fy) / 2, fy: fy);
}
