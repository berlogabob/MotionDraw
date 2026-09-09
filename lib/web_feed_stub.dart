import 'package:flutter/widgets.dart';

import 'camera_strip.dart';
import 'feeds.dart';

/// Non-web placeholder; the real one lives in web_feed.dart.
class WebCameraFeed implements CameraFeed {
  @override
  int get rotationDegrees => 0;
  @override
  bool get mirrored => false;
  @override
  Widget buildPreview(void Function(Frame) onFrame) =>
      throw UnsupportedError('web only');
}
