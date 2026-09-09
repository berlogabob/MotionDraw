import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'camera_strip.dart';
import 'feeds.dart';
import 'motion_detector.dart';
import 'sampler.dart';
import 'scale_mapper.dart';

/// Cells across the shorter side of the camera image, on every device.
const cellsAcross = 12;
const _matte = 28.0;
const _ink = Colors.black;
const _band = 10; // strip thickness in image pixels
const _style = TextStyle(fontSize: 11, letterSpacing: 1.5, color: _ink);

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

/// Grid geometry in image pixels. The grid is anchored at the image centre
/// with square cells, [cellsAcross] of them on the short side; the line axis
/// gets [bins] whole centred cells starting at [start].
class Geom {
  Geom(this.width, this.height, this.vertical)
      : cell = min(width, height) / cellsAcross {
    along = (vertical ? height : width).toDouble();
    across = (vertical ? width : height).toDouble();
    bins = 2 * (along / (2 * cell)).floor();
    start = along / 2 - bins / 2 * cell;
  }
  final int width;
  final int height;
  final bool vertical;
  final double cell;
  late final double along;
  late final double across;
  late final int bins;
  late final double start;

  /// Nearest grid line across the line axis, kept inside the image.
  double snap(double px) => (across / 2 + ((px - across / 2) / cell).round() * cell)
      .clamp(cell, across - cell)
      .toDouble();

  /// Where the image lands inside [area]: contain, centred.
  static Rect fit(Size area, int w, int h) {
    final s = min(area.width / w, area.height / h);
    final size = Size(w * s, h * s);
    return Alignment.center.inscribe(size, Offset.zero & area);
  }
}

/// One screen: the analysed camera frame drawn inside an adaptive
/// passepartout, a square grid anchored at the image centre, and a guide line
/// whose position along the line picks the pitch. Drag = move line,
/// double-tap = flip orientation. Caption rows and the ≡ menu are the controls.
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.sampler, required this.feed});
  final Sampler sampler;
  final CameraFeed feed;

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen>
    with SingleTickerProviderStateMixin {
  final _settings = Settings();
  MotionDetector? _detector;
  final _flash = ValueNotifier<List<double>>(const []);
  final _lastIntensity = ValueNotifier<double>(0);
  ui.Image? _image;
  Geom? _geom;
  bool _busy = false;
  bool _decoding = false;

  bool _vertical = true;
  bool _reversed = false;
  late bool _flipH = widget.feed.mirrorDefault;
  bool _flipV = false;
  double? _pos; // across the line axis, image px; null = centre

  // Static mode: the line sweeps as a playhead. Moving it over a still scene
  // turns every edge it crosses into a strip diff, which MotionDetector
  // already treats as a trigger. ponytail: low-contrast objects stay silent;
  // add a luminance threshold detector if edge triggering is not enough.
  bool _static = false;
  int _sweepSeconds = 8;
  late final AnimationController _head = AnimationController(
      vsync: this, duration: Duration(seconds: _sweepSeconds))
    ..addListener(() {
      final g = _geom;
      if (g == null) return;
      final t = _reversed ? 1 - _head.value : _head.value;
      setState(() => _pos = g.cell + t * (g.across - 2 * g.cell));
    });

  void _togglePlay() =>
      setState(() => _head.isAnimating ? _head.stop() : _head.repeat());

  void _cycleSweep() => setState(() {
        _sweepSeconds = _sweepSeconds == 16 ? 4 : _sweepSeconds * 2;
        _head.duration = Duration(seconds: _sweepSeconds);
        if (_head.isAnimating) _head.repeat();
      });

  Geom _geomFor(Gray g) {
    var geom = _geom;
    if (geom == null ||
        geom.width != g.width ||
        geom.height != g.height ||
        geom.vertical != _vertical) {
      geom = Geom(g.width, g.height, _vertical);
      if (_detector?.bins != geom.bins) {
        _detector = MotionDetector(bins: geom.bins)
          ..sensitivity = _settings.sensitivity;
        _flash.value = List.filled(geom.bins, 0);
      }
      _geom = geom;
    }
    return geom;
  }

  void _onFrame(Frame frame) {
    if (_busy) return; // drop frames rather than queue them
    _busy = true;
    try {
      final gray = orient(frame,
          rotation: widget.feed.rotationDegrees, flipH: _flipH, flipV: _flipV);
      final g = _geomFor(gray);
      final at = g.snap(_pos ?? g.across / 2);
      final strip = stripOf(gray,
          vertical: _vertical,
          at: at.round(),
          band: _band,
          start: g.start.round(),
          length: (g.bins * g.cell).round());
      final events =
          _detector!.process(strip, DateTime.now().millisecondsSinceEpoch);
      if (events.isNotEmpty) _fire(events, g.bins);
      if (!_decoding) {
        _decoding = true;
        ui.decodeImageFromPixels(
            rgbaOf(gray), gray.width, gray.height, ui.PixelFormat.rgba8888,
            (img) {
          _decoding = false;
          if (!mounted) return img.dispose();
          setState(() {
            _image?.dispose();
            _image = img;
          });
        });
      }
    } finally {
      _busy = false;
    }
  }

  void _fire(List<BinEvent> events, int bins) {
    final flash = List.of(_flash.value);
    for (final e in events) {
      // Strip index 0 = image top/left; bin 0 = low note = bottom/left.
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
  }

  @override
  void dispose() {
    _head.dispose();
    _flash.dispose();
    _lastIntensity.dispose();
    _image?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ widgets

  Widget _canvas() => LayoutBuilder(
        builder: (context, constraints) {
          final area = constraints.biggest;
          final g = _geom;
          final dst = g == null ? null : Geom.fit(area, g.width, g.height);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) {
              if (g == null || dst == null) return;
              final s = dst.width / g.width;
              final p = (d.localPosition - dst.topLeft) / s;
              setState(() => _pos = _vertical ? p.dx : p.dy);
            },
            onDoubleTap: () => setState(() => _vertical = !_vertical),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ValueListenableBuilder<List<double>>(
                  valueListenable: _flash,
                  builder: (context, flash, _) => CustomPaint(
                    painter: FramePainter(
                      image: _image,
                      geom: g,
                      dst: dst,
                      reversed: _reversed,
                      snap: !_head.isAnimating,
                      pos: _pos,
                      flash: flash,
                    ),
                  ),
                ),
                if (dst != null)
                  Positioned(
                    left: dst.left + 4,
                    top: dst.top + 16,
                    bottom: area.height - dst.bottom + 16,
                    width: 24,
                    child: RotatedBox(quarterTurns: 3, child: _slider()),
                  ),
              ],
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
            _detector?.sensitivity = v;
          }),
        ),
      );

  static Widget row(String label, String value, [VoidCallback? onTap]) {
    // Fixed label column: the theme font is proportional on some platforms,
    // so no padding trick would line the colons up.
    final r = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 64, child: Text(label.toUpperCase(), style: _style)),
        Text(': ${value.toUpperCase()}', style: _style),
      ],
    );
    return onTap == null
        ? r
        : GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: onTap, child: r);
  }

  Widget _caption() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('scale', _settings.scaleName, () => setState(_settings.cycleScale)),
          row('root', _settings.rootName, () => setState(_settings.cycleRoot)),
          row('line', _vertical ? 'vertical' : 'horizontal',
              () => setState(() => _vertical = !_vertical)),
          row(
              'low',
              _vertical
                  ? (_reversed ? 'top' : 'bottom')
                  : (_reversed ? 'right' : 'left'),
              () => setState(() => _reversed = !_reversed)),
          row('mode', _static ? 'static' : 'dynamic', () => setState(() {
                _static = !_static;
                if (!_static) _head.stop();
              })),
          if (_static) ...[
            row('play', _head.isAnimating ? 'playing' : 'stopped', _togglePlay),
            row('sweep', '${_sweepSeconds}s', _cycleSweep),
          ],
          row('sens', _settings.sensitivity.toStringAsFixed(2)),
        ],
      );

  Widget _menu() {
    final feed = widget.feed;
    final cams = feed.cameras;
    return PopupMenuButton<String>(
      tooltip: '',
      padding: EdgeInsets.zero,
      color: Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
          side: BorderSide(color: _ink), borderRadius: BorderRadius.zero),
      onSelected: (key) => setState(() {
        switch (key) {
          case 'camera':
            feed.index = (feed.index + 1) % max(1, cams.length);
          case 'fliph':
            _flipH = !_flipH;
          case 'flipv':
            _flipV = !_flipV;
          case 'synth':
            widget.sampler.cycleInstrument();
        }
      }),
      itemBuilder: (context) => [
        PopupMenuItem(
            value: 'camera',
            child: row('camera', cams.isEmpty ? '-' : cams[feed.index])),
        PopupMenuItem(value: 'fliph', child: row('flip h', _flipH ? 'on' : 'off')),
        PopupMenuItem(value: 'flipv', child: row('flip v', _flipV ? 'on' : 'off')),
        PopupMenuItem(
            value: 'synth', child: row('synth', widget.sampler.instrumentName)),
        PopupMenuItem(
          enabled: false,
          child: ValueListenableBuilder<double>(
            valueListenable: _lastIntensity,
            builder: (context, v, _) => row('last', '${(v * 100).round()}%'),
          ),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Text('≡', style: TextStyle(fontSize: 22, color: _ink)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Owns the platform camera; recreated when the camera changes.
            KeyedSubtree(
                key: ValueKey(widget.feed.index),
                child: widget.feed.host(_onFrame)),
            Column(
              children: [
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.fromLTRB(_matte, _matte, _matte, 0),
                    child: _canvas(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_matte, 16, _matte, 24),
                  child: Align(
                      alignment: Alignment.centerLeft, child: _caption()),
                ),
              ],
            ),
            Positioned(top: 0, right: 8, child: _menu()),
          ],
        ),
      ),
    );
  }
}

/// Draws, in image-pixel space: the frame, the centred grid, the guide line
/// with ticks on the crossings, and the flashed cell after the line. The
/// passepartout is whatever the image does not cover.
class FramePainter extends CustomPainter {
  FramePainter({
    required this.image,
    required this.geom,
    required this.dst,
    required this.reversed,
    required this.snap,
    required this.pos,
    required this.flash,
  });
  final ui.Image? image;
  final Geom? geom;
  final Rect? dst;
  final bool reversed;
  final bool snap; // grid-snapped when idle, continuous as a playhead
  final double? pos;
  final List<double> flash;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geom;
    final d = dst;
    if (g == null || d == null) {
      // No frame yet: an empty frame in the middle of the matte.
      canvas.drawRect(
          (Offset.zero & size).deflate(0.5),
          Paint()
            ..color = _ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      return;
    }
    final s = d.width / g.width;
    canvas.save();
    canvas.clipRect(d);
    canvas.translate(d.left, d.top);
    canvas.scale(s);
    final w = g.width.toDouble(), h = g.height.toDouble();
    final px = 1 / s; // one screen pixel
    if (image != null) {
      canvas.drawImageRect(
          image!,
          Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()),
          Rect.fromLTWH(0, 0, w, h),
          Paint()..filterQuality = FilterQuality.low);
    }
    final grid = Paint()
      ..color = _ink.withValues(alpha: 0.28)
      ..strokeWidth = px;
    final ink = Paint()
      ..color = _ink
      ..strokeWidth = px;
    final fill = Paint()..color = _ink;

    for (var x = w / 2 % g.cell; x <= w; x += g.cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (var y = h / 2 % g.cell; y <= h; y += g.cell) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    // (a = along the line, c = across) → canvas.
    Offset pt(double a, double c) => g.vertical ? Offset(c, a) : Offset(a, c);
    final raw = pos ?? g.across / 2;
    final lineC = snap ? g.snap(raw) : raw.clamp(0.0, g.across);
    canvas.drawLine(pt(0, lineC), pt(g.along, lineC), ink);
    for (var k = 0; k <= g.bins; k++) {
      final a = g.start + k * g.cell;
      canvas.drawLine(pt(a, lineC - 4 * px), pt(a, lineC + 4 * px), ink);
    }
    final n = min(flash.length, g.bins);
    for (var i = 0; i < n; i++) {
      if (flash[i] <= 0) continue;
      var b = reversed ? n - 1 - i : i;
      final slot = g.vertical ? n - 1 - b : b; // strip index from top/left
      final a0 = g.start + slot * g.cell;
      canvas.drawRect(
          Rect.fromPoints(pt(a0, lineC), pt(a0 + g.cell, lineC + g.cell)),
          fill);
    }
    canvas.restore();
    canvas.drawRect(
        d.deflate(0.5),
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(FramePainter old) => true;
}
