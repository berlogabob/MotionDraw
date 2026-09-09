import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_strip.dart';
import 'feeds.dart';
import 'motion_detector.dart';
import 'sampler.dart';
import 'scale_mapper.dart';

const bins = 15;
const _matte = 28.0;
const _ink = Colors.black;

/// Desaturate and lift the feed to a light grey so black ink reads on top.
/// Tune [_lift] (0..255) and [_gain] if the image goes muddy or blown out.
const _gain = 0.45;
const _lift = 145.0;
const _monoFilter = ColorFilter.matrix([
  _gain * 0.2126, _gain * 0.7152, _gain * 0.0722, 0, _lift, //
  _gain * 0.2126, _gain * 0.7152, _gain * 0.0722, 0, _lift, //
  _gain * 0.2126, _gain * 0.7152, _gain * 0.0722, 0, _lift, //
  0, 0, 0, 1, 0,
]);

const _roots = {
  'C': 48, 'C#': 49, 'D': 50, 'D#': 51, 'E': 52, 'F': 53, //
  'F#': 54, 'G': 55, 'G#': 56, 'A': 57, 'A#': 58, 'B': 59,
};

class Settings {
  double sensitivity = 1.0;
  String scaleName = 'pentatonic minor';
  int root = 57; // A3
  List<int> get intervals => scales[scaleName]!;
  String get rootName =>
      _roots.entries.firstWhere((e) => e.value == root).key;

  void cycleScale() => scaleName = _next(scales.keys.toList(), scaleName);
  void cycleRoot() => root = _next(_roots.values.toList(), root);

  static T _next<T>(List<T> items, T current) =>
      items[(items.indexOf(current) + 1) % items.length];
}

/// One screen: camera inside a passepartout frame, a square grid mapping
/// layer that flashes cells on trigger, and a draggable guide line whose
/// position along the line picks the pitch (higher/righter = higher). Drag =
/// move line, double-tap = flip orientation. Tap SCALE / ROOT to cycle.
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.sampler, required this.feed});
  final Sampler sampler;
  final CameraFeed feed;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    with SingleTickerProviderStateMixin {
  final _detector = MotionDetector(bins: bins);
  final _flash = ValueNotifier<List<double>>(List.filled(bins, 0));
  final _lastIntensity = ValueNotifier<double>(0);
  final _settings = Settings();
  bool _busy = false;

  // Frame-space line, drawn snapped to the grid. Low notes at bottom
  // (vertical) / left (horizontal) unless [_reversed].
  bool _vertical = true;
  bool _reversed = false;
  double _pos = 0.5;
  Size _frameSize = Size.zero;

  // Static mode: the line sweeps across the frame as a playhead. No detector
  // change needed — moving the line over a still scene turns every edge it
  // crosses into a strip diff, which MotionDetector already treats as a
  // trigger. ponytail: low-contrast objects stay silent; add a luminance
  // threshold detector if edge triggering is not enough.
  bool _static = false;
  int _sweepSeconds = 8;
  late final AnimationController _head = AnimationController(
      vsync: this, duration: Duration(seconds: _sweepSeconds))
    ..addListener(() => setState(() {
          final t = _reversed ? 1 - _head.value : _head.value;
          _pos = 0.05 + 0.9 * t;
        }));

  void _togglePlay() =>
      setState(() => _head.isAnimating ? _head.stop() : _head.repeat());

  void _cycleSweep() => setState(() {
        _sweepSeconds = _sweepSeconds == 16 ? 4 : _sweepSeconds * 2;
        _head.duration = Duration(seconds: _sweepSeconds);
        if (_head.isAnimating) _head.repeat();
      });

  void _onFrame(Frame frame) {
    if (_busy) return; // drop frames rather than queue them
    _busy = true;
    try {
      // The preview cover-crops the image into the frame; map the frame-space
      // line into image space and keep only the visible run of the strip.
      final rot = widget.feed.rotationDegrees % 180 == 90;
      final crop = coverCrop(
        (rot ? frame.height : frame.width).toDouble(),
        (rot ? frame.width : frame.height).toDouble(),
        _frameSize.width,
        _frameSize.height,
      );
      var line = screenToImageLine(
        screenVertical: _vertical,
        screenPos: _vertical
            ? crop.ox + _pos * crop.fx
            : crop.oy + _pos * crop.fy,
        rotationDegrees: widget.feed.rotationDegrees,
      );
      if (widget.feed.mirrored) line = line.mirroredX();
      final full = extractStrip(frame, line);
      final (o, f) = _vertical ? (crop.oy, crop.fy) : (crop.ox, crop.fx);
      final strip =
          full.sublist((o * full.length).round(), ((o + f) * full.length).round());
      final events =
          _detector.process(strip, DateTime.now().millisecondsSinceEpoch);
      if (events.isEmpty) return;
      final flash = List.of(_flash.value);
      for (final e in events) {
        // Strip index 0 = frame top/left; bin 0 = low note = bottom/left.
        var bin = _vertical ? bins - 1 - e.bin : e.bin;
        if (_reversed) bin = bins - 1 - bin;
        widget.sampler.playNote(
          binToMidi(bin, root: _settings.root, intervals: _settings.intervals),
          sqrt(e.intensity),
        );
        flash[bin] = 1;
        _lastIntensity.value = e.intensity;
      }
      _flash.value = flash;
      Future.delayed(const Duration(milliseconds: 250), () {
        _flash.value = List.filled(bins, 0);
      });
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _head.dispose();
    _flash.dispose();
    _lastIntensity.dispose();
    super.dispose();
  }

  Widget _frame() => LayoutBuilder(
        builder: (context, constraints) {
          final size = _frameSize = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => setState(() {
              _pos = (_vertical
                      ? d.localPosition.dx / size.width
                      : d.localPosition.dy / size.height)
                  .clamp(0.05, 0.95);
            }),
            onDoubleTap: () => setState(() => _vertical = !_vertical),
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: _ink)),
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColorFiltered(
                      colorFilter: _monoFilter,
                      child: widget.feed.buildPreview(_onFrame),
                    ),
                    ValueListenableBuilder<List<double>>(
                      valueListenable: _flash,
                      builder: (context, flash, _) => CustomPaint(
                        painter: FramePainter(
                          vertical: _vertical,
                          reversed: _reversed,
                          snap: !_head.isAnimating,
                          pos: _pos,
                          flash: flash,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 4,
                      top: 16,
                      bottom: 16,
                      width: 24,
                      child: RotatedBox(quarterTurns: 3, child: _slider()),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _slider() => SliderTheme(
        data: const SliderThemeData(
          trackHeight: 1,
          activeTrackColor: _ink,
          inactiveTrackColor: _ink,
          thumbColor: _ink,
          overlayColor: Colors.transparent,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
          trackShape: RectangularSliderTrackShape(),
        ),
        child: Slider(
          value: _settings.sensitivity,
          min: 0.25,
          max: 4,
          onChanged: (v) => setState(() {
            _settings.sensitivity = v;
            _detector.sensitivity = v;
          }),
        ),
      );

  Widget _row(String label, String value, [VoidCallback? onTap]) {
    const style = TextStyle(fontSize: 11, letterSpacing: 1.5, color: _ink);
    // Fixed label column: the theme font is proportional, so no padding trick
    // would line the colons up.
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 64, child: Text(label.toUpperCase(), style: style)),
        Text(': ${value.toUpperCase()}', style: style),
      ],
    );
    return onTap == null
        ? row
        : GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
  }

  Widget _caption() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('scale', _settings.scaleName,
              () => setState(_settings.cycleScale)),
          _row('root', _settings.rootName, () => setState(_settings.cycleRoot)),
          _row('line', _vertical ? 'vertical' : 'horizontal',
              () => setState(() => _vertical = !_vertical)),
          _row(
              'low',
              _vertical
                  ? (_reversed ? 'top' : 'bottom')
                  : (_reversed ? 'right' : 'left'),
              () => setState(() => _reversed = !_reversed)),
          _row('mode', _static ? 'static' : 'dynamic', () => setState(() {
                _static = !_static;
                if (!_static) _head.stop();
              })),
          if (_static) ...[
            _row('play', _head.isAnimating ? 'playing' : 'stopped',
                _togglePlay),
            _row('sweep', '${_sweepSeconds}s', _cycleSweep),
          ],
          _row('sens', _settings.sensitivity.toStringAsFixed(2)),
          ValueListenableBuilder<double>(
            valueListenable: _lastIntensity,
            builder: (context, v, _) =>
                _row('last', '${(v * 100).round()}%'),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_matte, _matte, _matte, 0),
                child: _frame(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(_matte, 16, _matte, 24),
              child: Align(alignment: Alignment.centerLeft, child: _caption()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mapping layer (grid + flashed cells) and guide layer (line + ticks).
/// Cells are square, [bins] of them tile the line axis from its start; the
/// perpendicular axis is gridded outward from the frame centre so the centre
/// line is always a grid line. The line snaps to that grid, ticks sit on the
/// crossings, and a triggered bin fills the cell just after the line.
class FramePainter extends CustomPainter {
  FramePainter({
    required this.vertical,
    required this.reversed,
    required this.snap,
    required this.pos,
    required this.flash,
  });
  final bool vertical;
  final bool reversed;
  final bool snap; // grid-snapped when idle, continuous as a playhead
  final double pos;
  final List<double> flash;

  @override
  void paint(Canvas canvas, Size size) {
    final n = flash.length;
    final along = vertical ? size.height : size.width;
    final across = vertical ? size.width : size.height;
    final cell = along / n;
    final mid = across / 2;
    final grid = Paint()
      ..color = _ink.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    final ink = Paint()
      ..color = _ink
      ..strokeWidth = 1;
    final fill = Paint()..color = _ink;

    // Work in (a = along the line, c = across) then map to canvas.
    Offset pt(double a, double c) => vertical ? Offset(c, a) : Offset(a, c);

    for (var k = 1; k < n; k++) {
      canvas.drawLine(pt(k * cell, 0), pt(k * cell, across), grid);
    }
    for (var c = mid % cell; c < across; c += cell) {
      canvas.drawLine(pt(0, c), pt(along, c), grid);
    }

    final lineC = snap
        ? mid + ((pos - 0.5) * across / cell).round() * cell
        : mid + (pos - 0.5) * across;
    canvas.drawLine(pt(0, lineC), pt(along, lineC), ink);
    for (var k = 1; k < n; k++) {
      canvas.drawLine(pt(k * cell, lineC - 4), pt(k * cell, lineC + 4), ink);
    }
    for (var i = 0; i < n; i++) {
      if (flash[i] <= 0) continue;
      // bin 0 = bottom (vertical) / left (horizontal) unless reversed.
      var slot = vertical ? n - 1 - i : i;
      if (reversed) slot = n - 1 - slot;
      final a0 = slot * cell;
      canvas.drawRect(
          Rect.fromPoints(pt(a0, lineC), pt(a0 + cell, lineC + cell)), fill);
    }
  }

  @override
  bool shouldRepaint(FramePainter old) =>
      old.pos != pos ||
      old.vertical != vertical ||
      old.reversed != reversed ||
      old.snap != snap ||
      old.flash != flash;
}
