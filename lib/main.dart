import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'canvas_screen.dart';
import 'feeds.dart';
import 'sampler.dart';
import 'scale_mapper.dart';
import 'web_feed_stub.dart' if (dart.library.js_interop) 'web_feed.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sampler = Sampler();
  // Browsers refuse audio before a user gesture: init after the first tap.
  if (!kIsWeb) await sampler.init();
  CameraFeed? feed;
  if (kIsWeb) {
    feed = WebCameraFeed();
  } else if (Platform.isMacOS) {
    feed = MacCameraFeed();
  } else {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) feed = MobileCameraFeed(cameras);
    } catch (_) {
      // No camera available → tap test mode.
    }
  }
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      fontFamily: 'monospace',
    ),
    home: feed == null
        ? TapTestScreen(sampler: sampler)
        : kIsWeb
            ? StartGate(sampler: sampler, feed: feed)
            : CanvasScreen(sampler: sampler, feed: feed),
  ));
}

/// Web only: one tap to unlock the browser's audio context, then the canvas.
class StartGate extends StatelessWidget {
  const StartGate({super.key, required this.sampler, required this.feed});
  final Sampler sampler;
  final CameraFeed feed;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          await sampler.init();
          if (!context.mounted) return;
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => CanvasScreen(sampler: sampler, feed: feed)));
        },
        child: const Scaffold(
          body: Center(
            child: Text(
              'TAP TO START',
              style: TextStyle(
                  fontSize: 11, letterSpacing: 1.5, color: Colors.black),
            ),
          ),
        ),
      );
}

/// Milestone 1 test mode: tap anywhere — vertical position picks the note.
/// Proves trigger latency and polyphony before any camera code exists.
class TapTestScreen extends StatefulWidget {
  const TapTestScreen({super.key, required this.sampler});
  final Sampler sampler;

  @override
  State<TapTestScreen> createState() => _TapTestScreenState();
}

class _TapTestScreenState extends State<TapTestScreen> {
  final _flash = List<double>.filled(cellsAcross, 0);

  void _tap(TapDownDetails d, Size size) {
    // Low notes at the bottom.
    final bin =
        ((1 - d.localPosition.dy / size.height) * cellsAcross).floor().clamp(0, cellsAcross - 1);
    widget.sampler.playNote(binToMidi(bin), 0.8);
    setState(() => _flash[bin] = 1);
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _flash[bin] = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _tap(d, constraints.biggest),
          child: CustomPaint(
            size: constraints.biggest,
            painter: _LinePainter(List.of(_flash)),
          ),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.flash);
  final List<double> flash;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.black
      ..strokeWidth = 1;
    final x = size.width / 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    final binH = size.height / cellsAcross;
    for (var i = 0; i < cellsAcross; i++) {
      final y = size.height - (i + 0.5) * binH;
      canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), line);
      if (flash[i] > 0) {
        canvas.drawCircle(Offset(x, y), 8, Paint()..color = Colors.black);
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}
