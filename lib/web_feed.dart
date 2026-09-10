import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'camera_strip.dart';
import 'feeds.dart';

/// Browser camera via getUserMedia. The camera plugin cannot stream frames on
/// web, so a detached <video> is sampled through an offscreen canvas.
class WebCameraFeed implements CameraFeed {
  final _ids = <String>[];
  final _names = <String>[];
  @override
  int index = 0;

  @override
  int get rotationDegrees => 0;

  @override
  bool get mirrorDefault => true;

  @override
  List<String> get cameras => _names.isEmpty ? const ['camera'] : _names;

  String? get _deviceId => index < _ids.length ? _ids[index] : null;

  /// Labels only exist once a stream has been granted.
  Future<void> _enumerate() async {
    final devs = (await web.window.navigator.mediaDevices.enumerateDevices().toDart).toDart;
    _ids.clear();
    _names.clear();
    for (final d in devs) {
      if (d.kind != 'videoinput') continue;
      _ids.add(d.deviceId);
      _names.add(d.label.isEmpty ? 'camera ${_ids.length}' : d.label);
    }
  }

  @override
  Widget host(void Function(Frame) onFrame) =>
      _WebHost(feed: this, onFrame: onFrame);
}

const _sampleWidth = 640; // detector needs no more

class _WebHost extends StatefulWidget {
  const _WebHost({required this.feed, required this.onFrame});
  final WebCameraFeed feed;
  final void Function(Frame) onFrame;

  @override
  State<_WebHost> createState() => _WebHostState();
}

class _WebHostState extends State<_WebHost> {
  final _video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true
    ..setAttribute('playsinline', '');
  final _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;
  Timer? _pump;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final id = widget.feed._deviceId;
    final video = id == null
        ? true.toJS
        : web.MediaTrackConstraints(deviceId: id.toJS) as JSAny;
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(web.MediaStreamConstraints(video: video))
        .toDart;
    if (!mounted) {
      for (final t in stream.getTracks().toDart) {
        t.stop();
      }
      return;
    }
    _video.srcObject = _stream = stream;
    await widget.feed._enumerate();
    _pump = Timer.periodic(const Duration(milliseconds: 33), (_) => _grab());
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
    for (final t in _stream?.getTracks().toDart ?? const <web.MediaStreamTrack>[]) {
      t.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Browser fullscreen toggle; must be called from a user gesture.
void toggleFullscreen() {
  if (web.document.fullscreenElement == null) {
    web.document.documentElement?.requestFullscreen();
  } else {
    web.document.exitFullscreen();
  }
}
