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
const matte = 24.0;
const ink = Colors.black;
const _band = 10; // strip thickness in image pixels
const captionStyle = TextStyle(fontSize: 11, letterSpacing: 1.0, color: ink);
const _column = 160.0; // caption column width: two fit a phone, three a laptop
const _sensSteps = [0.5, 1.0, 2.0, 4.0];

const _roots = {
  'C': 48, 'C#': 49, 'D': 50, 'D#': 51, 'E': 52, 'F': 53, //
  'F#': 54, 'G': 55, 'G#': 56, 'A': 57, 'A#': 58, 'B': 59,
};

class Settings {
  double sensitivity = 1.0;
  String scaleName = 'penta minor';
  int root = 57; // A3
  List<int> get intervals => scales[scaleName]!;
  String get rootName =>
      _roots.entries.firstWhere((e) => e.value == root).key;

  void cycleScale() => scaleName = _next(scales.keys.toList(), scaleName);
  void cycleRoot() => root = _next(_roots.values.toList(), root);
  void cycleSensitivity() {
    final i = _sensSteps.indexWhere((s) => s > sensitivity + 1e-9);
    sensitivity = i < 0 ? _sensSteps.first : _sensSteps[i];
  }

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
  double snap(double px) =>
      (across / 2 + ((px - across / 2) / cell).round() * cell)
          .clamp(cell, across - cell)
          .toDouble();

  /// Where the image lands inside [area]: contain, top-centred, so the
  /// passepartout keeps equal sides and puts its weight at the bottom.
  static Rect fit(Size area, int w, int h) {
    final s = min(area.width / w, area.height / h);
    return Alignment.topCenter.inscribe(Size(w * s, h * s), Offset.zero & area);
  }
}

/// A caption row: `LABEL : VALUE`, tap to cycle, optional horizontal drag.
Widget captionRow(String label, String value,
    {VoidCallback? onTap, void Function(double dx)? onDrag}) {
  final text = Text(
    '${label.toUpperCase().padRight(6)} : ${value.toUpperCase()}',
    style: captionStyle,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
  if (onTap == null && onDrag == null) return text;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    onHorizontalDragUpdate: onDrag == null ? null : (d) => onDrag(d.delta.dx),
    child: text,
  );
}

/// One screen: the analysed camera frame drawn inside an adaptive
/// passepartout, a square grid anchored at the image centre, and a guide line
/// whose position along the line picks the pitch. Drag = move line,
/// double-tap = flip orientation. Every control is a caption row.
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
  double _frameLeft = 0; // caption lines up with the frame's left edge
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

  void _setSensitivity(double v) => setState(() {
        _settings.sensitivity = v.clamp(0.25, 4.0);
        _detector?.sensitivity = _settings.sensitivity;
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
          // Before the first frame: an empty 4:3 frame in the same place.
          final dst = g == null
              ? Geom.fit(area, 4, 3)
              : Geom.fit(area, g.width, g.height);
          if (dst.left != _frameLeft) {
            // Layout-time value; the caption picks it up on the next build.
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => mounted ? setState(() => _frameLeft = dst.left) : null);
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) {
              if (g == null) return;
              final s = dst.width / g.width;
              final p = (d.localPosition - dst.topLeft) / s;
              setState(() => _pos = _vertical ? p.dx : p.dy);
            },
            onDoubleTap: () => setState(() => _vertical = !_vertical),
            child: ValueListenableBuilder<List<double>>(
              valueListenable: _flash,
              builder: (context, flash, _) => CustomPaint(
                size: area,
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
          );
        },
      );

  List<Widget> _music() => [
        captionRow('scale', _settings.scaleName,
            onTap: () => setState(_settings.cycleScale)),
        captionRow('root', _settings.rootName,
            onTap: () => setState(_settings.cycleRoot)),
        captionRow('synth', widget.sampler.instrumentName,
            onTap: () => setState(widget.sampler.cycleInstrument)),
        captionRow('sens', _settings.sensitivity.toStringAsFixed(2),
            onTap: () => setState(_settings.cycleSensitivity),
            onDrag: (dx) => _setSensitivity(_settings.sensitivity + dx / 100)),
      ];

  List<Widget> _line() => [
        captionRow('line', _vertical ? 'vertical' : 'horizontal',
            onTap: () => setState(() => _vertical = !_vertical)),
        captionRow(
            'low',
            _vertical
                ? (_reversed ? 'top' : 'bottom')
                : (_reversed ? 'right' : 'left'),
            onTap: () => setState(() => _reversed = !_reversed)),
        captionRow('mode', _static ? 'static' : 'dynamic', onTap: () {
          setState(() {
            _static = !_static;
            if (!_static) _head.stop();
          });
        }),
        if (_static) ...[
          captionRow('play', _head.isAnimating ? 'playing' : 'stopped',
              onTap: _togglePlay),
          captionRow('sweep', '${_sweepSeconds}s', onTap: _cycleSweep),
        ],
      ];

  List<Widget> _camera() {
    final feed = widget.feed;
    final cams = feed.cameras;
    return [
      captionRow(
          'camera',
          _geom == null
              ? 'waiting'
              : cams.isEmpty
                  ? '-'
                  : cams[feed.index],
          onTap: cams.length < 2
              ? null
              : () => setState(() => feed.index = (feed.index + 1) % cams.length)),
      captionRow('flip h', _flipH ? 'on' : 'off',
          onTap: () => setState(() => _flipH = !_flipH)),
      captionRow('flip v', _flipV ? 'on' : 'off',
          onTap: () => setState(() => _flipV = !_flipV)),
      ValueListenableBuilder<double>(
        valueListenable: _lastIntensity,
        builder: (context, v, _) => captionRow('last', '${(v * 100).round()}%'),
      ),
    ];
  }

  Widget _caption() => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final rows in [_music(), _line(), _camera()])
            SizedBox(
              width: _column,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rows,
              ),
            ),
        ],
      );

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
            Padding(
              padding: const EdgeInsets.fromLTRB(matte, matte, matte, matte),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _canvas()),
                  const SizedBox(height: 16),
                  Padding(
                      padding: EdgeInsets.only(left: _frameLeft),
                      child: _caption()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws, in image-pixel space: the frame, the centred grid, the guide line,
/// and the flashed cell after the line. The passepartout is whatever the
/// image does not cover.
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
  final Rect dst;
  final bool reversed;
  final bool snap; // grid-snapped when idle, continuous as a playhead
  final double? pos;
  final List<double> flash;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final g = geom;
    if (g == null) {
      canvas.drawRect(dst.deflate(0.5), border);
      return;
    }
    final s = dst.width / g.width;
    canvas.save();
    canvas.clipRect(dst);
    canvas.translate(dst.left, dst.top);
    canvas.scale(s);
    final w = g.width.toDouble(), h = g.height.toDouble();
    final px = 1 / s; // one screen pixel
    if (image != null) {
      canvas.drawImageRect(
          image!,
          Rect.fromLTWH(
              0, 0, image!.width.toDouble(), image!.height.toDouble()),
          Rect.fromLTWH(0, 0, w, h),
          Paint()..filterQuality = FilterQuality.low);
    }
    final grid = Paint()
      ..color = ink.withValues(alpha: 0.16)
      ..strokeWidth = px;
    final line = Paint()
      ..color = ink
      ..strokeWidth = 2 * px;
    final fill = Paint()..color = ink;

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
    canvas.drawLine(pt(0, lineC), pt(g.along, lineC), line);
    final n = min(flash.length, g.bins);
    for (var i = 0; i < n; i++) {
      if (flash[i] <= 0) continue;
      final b = reversed ? n - 1 - i : i;
      final slot = g.vertical ? n - 1 - b : b; // strip index from top/left
      final a0 = g.start + slot * g.cell;
      canvas.drawRect(
          Rect.fromPoints(pt(a0, lineC), pt(a0 + g.cell, lineC + g.cell)),
          fill);
    }
    canvas.restore();
    canvas.drawRect(dst.deflate(0.5), border);
  }

  @override
  bool shouldRepaint(FramePainter old) => true;
}
