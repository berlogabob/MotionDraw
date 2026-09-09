import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_strip.dart';
import 'feeds.dart';

/// Browser camera via getUserMedia. The camera plugin cannot stream frames on
/// web, so a <video> is shown as a platform view and an offscreen canvas
/// samples it for the detector.
class WebCameraFeed implements CameraFeed {
  @override
  int get rotationDegrees => 0;

  @override
  bool get mirrored => false; // video shown as captured, frames match

  @override
  Widget buildPreview(void Function(Frame) onFrame) =>
      _WebPreview(onFrame: onFrame);
}

const _viewType = 'motiondraw-video';
const _sampleWidth = 320; // detector needs no more

class _WebPreview extends StatefulWidget {
  const _WebPreview({required this.onFrame});
  final void Function(Frame) onFrame;

  @override
  State<_WebPreview> createState() => _WebPreviewState();
}

class _WebPreviewState extends State<_WebPreview> {
  final _video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true
    ..setAttribute('playsinline', '')
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.objectFit = 'cover'
    // ColorFiltered cannot touch a platform view; approximate the mono lift.
    ..style.filter = 'grayscale(1) brightness(1.35) contrast(0.55)';
  final _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;
  Timer? _pump;

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _video);
    web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
        .toDart
        .then((stream) {
      if (!mounted) return;
      _video.srcObject = _stream = stream;
      _pump = Timer.periodic(const Duration(milliseconds: 33), (_) => _grab());
    });
  }

  void _grab() {
    final vw = _video.videoWidth;
    final vh = _video.videoHeight;
    if (vw == 0 || vh == 0) return;
    final w = _sampleWidth;
    final h = (vh * w / vw).round();
    if (_canvas.width != w || _canvas.height != h) {
      _canvas.width = w;
      _canvas.height = h;
    }
    final ctx = _canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(_video, 0, 0, w, h);
    final data = ctx.getImageData(0, 0, w, h).data.toDart;
    widget.onFrame(Frame(
      bytes: Uint8List.view(data.buffer),
      width: w,
      height: h,
      stride: w * 4,
      pixelStride: 4,
      channelOffset: 1, // RGBA → green ≈ luminance
    ));
  }

  @override
  void dispose() {
    _pump?.cancel();
    final tracks = _stream?.getTracks().toDart ?? const [];
    for (final t in tracks) {
      t.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const HtmlElementView(viewType: _viewType);
}
