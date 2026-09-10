import 'package:flutter/widgets.dart';

import 'camera_strip.dart';
import 'feeds.dart';

/// Non-web placeholder; the real one lives in web_feed.dart.
class WebCameraFeed implements CameraFeed {
  @override
  int get rotationDegrees => 0;
  @override
  bool get mirrorDefault => true;
  @override
  List<String> get cameras => const [];
  @override
  int index = 0;
  @override
  Widget host(void Function(Frame) onFrame) =>
      throw UnsupportedError('web only');
}

/// Web only.
void toggleFullscreen() {}
