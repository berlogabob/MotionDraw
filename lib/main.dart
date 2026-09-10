import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'canvas_screen.dart';
import 'feeds.dart';
import 'sampler.dart';
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
      fontFamily: 'IBM Plex Mono',
    ),
    home: feed == null
        ? Scaffold(body: Center(child: captionRow('camera', 'none')))
        : kIsWeb
            ? StartGate(sampler: sampler, feed: feed)
            : CanvasScreen(sampler: sampler, feed: feed),
  ));
}

/// Web only: one tap to unlock the browser's audio context, then the canvas.
/// Drawn as the same screen: empty frame plus one caption row.
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
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(matte),
              child: LayoutBuilder(
                builder: (context, c) {
                  final area = Size(c.maxWidth, c.maxHeight - 32);
                  final dst = Geom.fit(area, 4, 3);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CustomPaint(
                        size: area,
                        painter: FramePainter(
                          image: null,
                          geom: null,
                          dst: dst,
                          reversed: false,
                          snap: true,
                          pos: null,
                          flash: const [],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                          padding: EdgeInsets.only(left: dst.left),
                          child: captionRow('start', 'tap anywhere')),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
}
