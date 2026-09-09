import 'dart:typed_data';

class BinEvent {
  const BinEvent(this.bin, this.intensity);
  final int bin;

  /// 0..1 motion strength at trigger time.
  final double intensity;
}

/// Frame-differencing trigger detector over a 1-D grayscale strip.
///
/// Pipeline: per-pixel |diff| vs previous strip → mean per bin → EMA →
/// global-motion rejection → Schmitt trigger with 2-frame confirmation and
/// per-bin refractory period.
///
/// Pass the current time into [process] — the class holds no clock, so tests
/// drive it deterministically.
class MotionDetector {
  MotionDetector({
    this.bins = 15,
    this.sensitivity = 1.0,
    this.refractoryMs = 150,
  })  : _ema = List.filled(bins, 0),
        _overCount = List.filled(bins, 0),
        _armed = List.filled(bins, true),
        _lastFireMs = List.filled(bins, -1 << 40);

  final int bins;

  /// User slider, ~0.25 (needs big motion) .. 4 (very touchy). Scales the
  /// trigger threshold inversely.
  double sensitivity;
  final int refractoryMs;

  static const _baseThreshold = 30 / 255; // research consensus starting point
  static const _emaAlpha = 0.4;
  static const _schmittLowRatio = 0.6;
  static const _confirmFrames = 2;
  static const _globalRejectFraction = 0.7;

  Uint8List? _prev;
  final List<double> _ema;
  final List<int> _overCount;
  final List<bool> _armed;
  final List<int> _lastFireMs;

  double get _tHigh => _baseThreshold / sensitivity;
  double get _tLow => _tHigh * _schmittLowRatio;

  /// Feed one grayscale strip (any length ≥ [bins]); returns bins that fired.
  List<BinEvent> process(Uint8List strip, int nowMs) {
    final prev = _prev;
    _prev = Uint8List.fromList(strip);
    if (prev == null || prev.length != strip.length) return const [];

    // Mean absolute diff per bin, normalized to 0..1.
    final activity = List<double>.filled(bins, 0);
    final perBin = strip.length / bins;
    for (var i = 0; i < strip.length; i++) {
      activity[(i ~/ perBin).clamp(0, bins - 1)] +=
          (strip[i] - prev[i]).abs() / 255;
    }
    for (var b = 0; b < bins; b++) {
      activity[b] /= perBin;
      _ema[b] = _emaAlpha * activity[b] + (1 - _emaAlpha) * _ema[b];
    }

    // Global motion (camera shake, light switch): everything lit → ignore.
    final active = _ema.where((a) => a > _tHigh).length;
    if (active > bins * _globalRejectFraction) {
      for (var b = 0; b < bins; b++) {
        _overCount[b] = 0;
        _armed[b] = false; // re-arm only after the scene settles
      }
      return const [];
    }

    final events = <BinEvent>[];
    for (var b = 0; b < bins; b++) {
      final a = _ema[b];
      if (a < _tLow) {
        _armed[b] = true;
        _overCount[b] = 0;
      } else if (a > _tHigh && _armed[b]) {
        _overCount[b]++;
        if (_overCount[b] >= _confirmFrames &&
            nowMs - _lastFireMs[b] >= refractoryMs) {
          _lastFireMs[b] = nowMs;
          _armed[b] = false;
          _overCount[b] = 0;
          events.add(BinEvent(b, a.clamp(0.0, 1.0)));
        }
      }
    }
    return events;
  }
}
