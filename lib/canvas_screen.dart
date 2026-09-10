import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'camera_strip.dart';
import 'feeds.dart';
import 'web_feed_stub.dart' if (dart.library.js_interop) 'web_feed.dart';
import 'motion_detector.dart';
import 'sampler.dart';
import 'scale_mapper.dart';
import 'sequence.dart';

/// Cells across the shorter side of the camera image, on every device.
const cellsAcross = 12;
const matte = 24.0;
const ink = Colors.black;
const _band = 10; // strip thickness in image pixels
const captionReserve = 72.0; // three caption lines under the frame
const _bpmSteps = [80, 100, 120, 140, 160];

enum Tempo { off, quant, seq }
const captionStyle = TextStyle(fontSize: 11, letterSpacing: 1.0, color: ink);
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
  /// Value plus direction, since 0.25 is the *least* touchy setting.
  String get sensitivityLabel {
    const words = ['low', 'mid', 'high', 'max'];
    var i = 0;
    while (i < _sensSteps.length - 1 && sensitivity >= _sensSteps[i + 1] - 1e-9) {
      i++;
    }
    return '${sensitivity.toStringAsFixed(2)} ${words[i]}';
  }

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
    value.isEmpty
        ? label.toUpperCase()
        : '${label.toUpperCase().padRight(6)} : ${value.toUpperCase()}',
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
  StripDetector? _detector;
  final _flash = ValueNotifier<List<double>>(const []);
  final _lastIntensity = ValueNotifier<double>(0);
  ui.Image? _image;
  Geom? _geom;
  bool _settingsOpen = false;

  // Tempo sync. QUANT: detected notes wait for the next grid tick and play
  // together. SEQ: detections fill a looping step sequence played one note
  // per tick.
  Tempo _tempo = Tempo.off;
  int _bpm = 120;
  int _div = 8; // 4 | 8 | 16
  Timer? _clock;
  int _tickCount = 0;
  // Visual click: 0 = off, 1 = subdivision, 2 = downbeat (quarter note).
  final _beat = ValueNotifier<int>(0);
  final _pending = <int, double>{}; // bin → intensity (quant)
  final _seq = Sequence(16);
  bool _loop = true; // seq: loop the sequence, or play each note once
  final _queue = <(int, double)>[]; // seq once: oldest first
  int _bins = 0; // bins of the last detection, for flash length

  void _blink(int kind) {
    _beat.value = kind;
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) _beat.value = 0;
    });
  }

  void _restartClock() {
    _clock?.cancel();
    _clock = null;
    _tickCount = 0;
    _beat.value = 0;
    if (_tempo == Tempo.off) return;
    _clock = Timer.periodic(
        Duration(milliseconds: tickMs(_bpm, _div)), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    _blink(_tickCount++ % (_div ~/ 4) == 0 ? 2 : 1);
    final flash = List<double>.filled(_bins, 0);
    switch (_tempo) {
      case Tempo.quant:
        if (_pending.isEmpty) return;
        for (final e in _pending.entries) {
          _play(e.key, e.value);
          if (e.key < flash.length) flash[e.key] = 1;
        }
        _pending.clear();
      case Tempo.seq:
        final n = _loop
            ? _seq.tick()
            : (_queue.isEmpty ? null : _queue.removeAt(0));
        if (n == null) return;
        _play(n.$1, n.$2);
        if (n.$1 < flash.length) flash[n.$1] = 1;
      case Tempo.off:
        return;
    }
    _showFlash(flash);
  }

  void _play(int bin, double intensity) => widget.sampler.playNote(
        binToMidi(bin, root: _settings.root, intervals: _settings.intervals),
        sqrt(intensity),
      );

  void _showFlash(List<double> flash) {
    _flash.value = flash;
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _flash.value = List.filled(flash.length, 0);
    });
  }
  bool _busy = false;
  bool _decoding = false;

  bool _vertical = true;
  bool _reversed = false;
  late bool _flipH = widget.feed.mirrorDefault;
  bool _flipV = false;
  double? _pos; // across the line axis, image px; null = centre

  // Static mode: the line sweeps as a playhead over a still scene, and
  // StaticDetector scores each bin by its contrast against the strip median.
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

  StripDetector _makeDetector(int bins) => (_static
      ? StaticDetector(bins: bins)
      : MotionDetector(bins: bins))
    ..sensitivity = _settings.sensitivity;

  Geom _geomFor(Gray g) {
    var geom = _geom;
    if (geom == null ||
        geom.width != g.width ||
        geom.height != g.height ||
        geom.vertical != _vertical) {
      geom = Geom(g.width, g.height, _vertical);
      if (_detector?.bins != geom.bins) {
        _detector = _makeDetector(geom.bins);
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
    final flash = List<double>.filled(bins, 0);
    for (final e in events) {
      // Strip index 0 = image top/left; bin 0 = low note = bottom/left.
      var bin = _vertical ? bins - 1 - e.bin : e.bin;
      if (_reversed) bin = bins - 1 - bin;
      _lastIntensity.value = e.intensity;
      _bins = bins;
      switch (_tempo) {
        case Tempo.quant:
          _pending[bin] = max(_pending[bin] ?? 0, e.intensity);
        case Tempo.seq:
          if (_loop) {
            _seq.add(bin, e.intensity);
          } else {
            _queue.add((bin, e.intensity));
          }
        case Tempo.off:
          _play(bin, e.intensity);
          flash[bin] = 1;
      }
    }
    if (_tempo == Tempo.off) _showFlash(flash);
  }

  @override
  void dispose() {
    _clock?.cancel();
    _beat.dispose();
    _head.dispose();
    _flash.dispose();
    _lastIntensity.dispose();
    _image?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ widgets

  Widget _canvas() => LayoutBuilder(
        builder: (context, constraints) {
          // The Stack spans the whole area so the caption below the frame is
          // still inside it (hit-testing stops at the Stack's box); the frame
          // itself is fitted into the area minus the caption reserve.
          final area = constraints.biggest;
          final fitArea = Size(area.width, area.height - captionReserve);
          final g = _geom;
          // Before the first frame: an empty 4:3 frame in the same place.
          final dst = g == null
              ? Geom.fit(fitArea, 4, 3)
              : Geom.fit(fitArea, g.width, g.height);
          final picture = GestureDetector(
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
          return Stack(
            clipBehavior: Clip.none,
            children: [
              picture,
              // Caption sits right under the frame, wherever the frame ends.
              Positioned(
                  left: dst.left, top: dst.bottom + 16, child: _caption()),
              if (_settingsOpen)
                Positioned.fromRect(rect: dst, child: _settingsSheet()),
              // Hamburger: three ink lines, flush with the frame's top-right.
              Positioned(
                top: dst.top,
                left: dst.right - 32,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _settingsOpen = !_settingsOpen),
                  child: const CustomPaint(
                      size: Size(32, 32), painter: _HamburgerPainter()),
                ),
              ),
            ],
          );
        },
      );

  Widget _row(List<Widget> items) => Wrap(spacing: 24, children: items);

  /// Two lines: what you touch while playing.
  Widget _caption() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row([
            captionRow('mode', _static ? 'static' : 'dynamic', onTap: () {
              setState(() {
                _static = !_static;
                if (!_static) _head.stop();
                final g = _geom;
                if (g != null) _detector = _makeDetector(g.bins);
              });
            }),
            if (_static) ...[
              captionRow('play', _head.isAnimating ? 'playing' : 'stopped',
                  onTap: _togglePlay),
              captionRow('sweep', '${_sweepSeconds}s', onTap: _cycleSweep),
            ],
          ]),
          _row([
            captionRow('line', _vertical ? 'vertical' : 'horizontal',
                onTap: () => setState(() => _vertical = !_vertical)),
            captionRow(
                'low',
                _vertical
                    ? (_reversed ? 'top' : 'bottom')
                    : (_reversed ? 'right' : 'left'),
                onTap: () => setState(() => _reversed = !_reversed)),
          ]),
          _row([
            captionRow('tempo', _tempo.name, onTap: () {
              setState(() {
                _tempo = Tempo.values[(_tempo.index + 1) % Tempo.values.length];
                _pending.clear();
                _restartClock();
              });
            }),
            if (_tempo != Tempo.off) ...[
              captionRow('bpm', '$_bpm', onTap: () {
                setState(() {
                  final i = _bpmSteps.indexWhere((b) => b > _bpm);
                  _bpm = i < 0 ? _bpmSteps.first : _bpmSteps[i];
                  _restartClock();
                });
              }, onDrag: (dx) {
                setState(() {
                  _bpm = (_bpm + (dx / 2).round()).clamp(40, 240);
                  _restartClock();
                });
              }),
              captionRow('div', '1/$_div', onTap: () {
                setState(() {
                  _div = _div == 16 ? 4 : _div * 2;
                  _restartClock();
                });
              }),
            ],
            if (_tempo == Tempo.seq) ...[
              captionRow('seq', _loop ? 'loop' : 'once',
                  onTap: () => setState(() => _loop = !_loop)),
              if (_loop)
                captionRow('len', '${_seq.steps}',
                    onTap: () => setState(() =>
                        _seq.resize(_seq.steps == 32 ? 8 : _seq.steps * 2))),
              captionRow('clear', '', onTap: () {
                setState(() {
                  _seq.clear();
                  _queue.clear();
                });
              }),
            ],
            if (_tempo != Tempo.off)
              ValueListenableBuilder<int>(
                valueListenable: _beat,
                builder: (context, kind, _) => CustomPaint(
                    size: const Size(16, 16), painter: _BeatPainter(kind)),
              ),
          ]),
        ],
      );

  /// Everything else, as a sheet over the frame window. The camera keeps
  /// streaming underneath.
  Widget _settingsSheet() {
    final feed = widget.feed;
    final cams = feed.cameras;
    return DecoratedBox(
      decoration: BoxDecoration(
          color: Colors.white, border: Border.all(color: ink)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 48, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              captionRow('scale', _settings.scaleName,
                  onTap: () => setState(_settings.cycleScale)),
              captionRow('root', _settings.rootName,
                  onTap: () => setState(_settings.cycleRoot)),
              captionRow('synth', widget.sampler.instrumentName,
                  onTap: () => setState(widget.sampler.cycleInstrument)),
              captionRow('sens', _settings.sensitivityLabel,
                  onTap: () => setState(_settings.cycleSensitivity)),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: _Track(
                    value: _settings.sensitivity, onChanged: _setSensitivity),
              ),
              captionRow(
                  'camera',
                  _geom == null
                      ? 'waiting'
                      : cams.isEmpty
                          ? '-'
                          : cams[feed.index],
                  onTap: cams.length < 2
                      ? null
                      : () => setState(
                          () => feed.index = (feed.index + 1) % cams.length)),
              captionRow('flip h', _flipH ? 'on' : 'off',
                  onTap: () => setState(() => _flipH = !_flipH)),
              captionRow('flip v', _flipV ? 'on' : 'off',
                  onTap: () => setState(() => _flipV = !_flipV)),
              ValueListenableBuilder<double>(
                valueListenable: _lastIntensity,
                builder: (context, v, _) =>
                    captionRow('last', '${(v * 100).round()}%'),
              ),
              if (kIsWeb)
                captionRow('fullscreen', '', onTap: toggleFullscreen),
              const SizedBox(height: 16),
              captionRow('close', '',
                  onTap: () => setState(() => _settingsOpen = false)),
            ],
          ),
        ),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(matte, matte, matte, matte),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _canvas()),
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

class _HamburgerPainter extends CustomPainter {
  const _HamburgerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..strokeWidth = 1;
    const w = 14.0;
    final x0 = size.width - w - 8;
    for (var i = 0; i < 3; i++) {
      final y = 10.0 + i * 4;
      canvas.drawLine(Offset(x0, y), Offset(x0 + w, y), p);
    }
  }

  @override
  bool shouldRepaint(_HamburgerPainter old) => false;
}

/// Sensitivity track: 1 px line, square knob, log scale 0.25…4 so the four
/// presets sit evenly. Drag anywhere on it.
class _Track extends StatelessWidget {
  const _Track({required this.value, required this.onChanged});
  final double value;
  final void Function(double) onChanged;

  static double _toT(double v) => log(v / 0.25) / log(16);
  static double _fromT(double t) => 0.25 * pow(16, t.clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) =>
              onChanged(_fromT(d.localPosition.dx / c.maxWidth)),
          onTapDown: (d) => onChanged(_fromT(d.localPosition.dx / c.maxWidth)),
          child: CustomPaint(
            size: Size(c.maxWidth, 16),
            painter: _TrackPainter(_toT(value)),
          ),
        ),
      );
}

class _TrackPainter extends CustomPainter {
  _TrackPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..strokeWidth = 1;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    final x = (t * (size.width - 8)).clamp(0.0, size.width - 8);
    canvas.drawRect(Rect.fromLTWH(x, y - 4, 8, 8), Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.t != t;
}

/// The metronome square: outline between ticks, filled on a subdivision,
/// filled and double-size on the downbeat.
class _BeatPainter extends CustomPainter {
  _BeatPainter(this.kind);
  final int kind;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = kind == 2 ? 7.0 : 4.0;
    final rect = Rect.fromCenter(center: c, width: 2 * r, height: 2 * r);
    canvas.drawRect(
        rect,
        Paint()
          ..color = ink
          ..style = kind == 0 ? PaintingStyle.stroke : PaintingStyle.fill
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_BeatPainter old) => old.kind != kind;
}
