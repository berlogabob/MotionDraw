import 'package:camera/camera.dart';
import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

import 'camera_strip.dart';

/// A source of raw camera frames. No platform preview is ever shown: the
/// canvas draws the frames itself, so [host] is a zero-size widget that only
/// owns the platform camera lifecycle.
abstract class CameraFeed {
  /// Clockwise quarter turns from sensor space to screen space.
  int get rotationDegrees;

  /// Selfie cameras start mirrored, like a mirror.
  bool get mirrorDefault;

  List<String> get cameras;
  int get index;
  set index(int i);

  /// Owns the camera; rebuild it (new key) after changing [index].
  Widget host(void Function(Frame) onFrame);
}

// ---------------------------------------------------------------- iOS/Android

class MobileCameraFeed implements CameraFeed {
  MobileCameraFeed(this._cameras);
  final List<CameraDescription> _cameras;
  @override
  int index = 0;

  CameraDescription get _cam => _cameras[index];

  @override
  int get rotationDegrees => _cam.sensorOrientation;

  @override
  bool get mirrorDefault => _cam.lensDirection == CameraLensDirection.front;

  @override
  List<String> get cameras =>
      [for (final c in _cameras) c.lensDirection.name];

  @override
  Widget host(void Function(Frame) onFrame) =>
      _MobileHost(camera: _cam, onFrame: onFrame);
}

class _MobileHost extends StatefulWidget {
  const _MobileHost({required this.camera, required this.onFrame});
  final CameraDescription camera;
  final void Function(Frame) onFrame;

  @override
  State<_MobileHost> createState() => _MobileHostState();
}

class _MobileHostState extends State<_MobileHost> with WidgetsBindingObserver {
  CameraController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    final controller = CameraController(
      widget.camera,
      ResolutionPreset.medium, // ponytail: drop to low if a phone stutters
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    if (!mounted) {
      controller.dispose();
      return;
    }
    _controller = controller;
    await controller.startImageStream((img) {
      final y = img.planes[0];
      widget.onFrame(Frame(
        bytes: y.bytes,
        width: img.width,
        height: img.height,
        stride: y.bytesPerRow,
      ));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// --------------------------------------------------------------------- macOS

class MacCameraFeed implements CameraFeed {
  final _devices = <CameraMacOSDevice>[];
  @override
  int index = 0;

  @override
  int get rotationDegrees => 0;

  @override
  bool get mirrorDefault => true;

  @override
  List<String> get cameras =>
      [for (final d in _devices) d.localizedName ?? d.deviceId];

  String? get _deviceId => index < _devices.length ? _devices[index].deviceId : null;

  @override
  Widget host(void Function(Frame) onFrame) =>
      _MacHost(feed: this, onFrame: onFrame);
}

class _MacHost extends StatefulWidget {
  const _MacHost({required this.feed, required this.onFrame});
  final MacCameraFeed feed;
  final void Function(Frame) onFrame;

  @override
  State<_MacHost> createState() => _MacHostState();
}

class _MacHostState extends State<_MacHost> {
  @override
  void initState() {
    super.initState();
    // Listing prompts for camera permission; do it after the UI is up, not
    // before runApp, so the window is never black while the prompt waits.
    if (widget.feed._devices.isEmpty) {
      CameraMacOSPlatform.instance
          .listDevices(deviceType: CameraMacOSDeviceType.video)
          .then((d) => widget.feed._devices
            ..clear()
            ..addAll(d));
    }
  }

  // The plugin only streams frames from copyPixelBuffer(), which the engine
  // calls when its Texture is actually painted — so the view must stay in the
  // tree and painted: 1×1 px at 1% opacity (opacity 0 would skip painting).
  // Frames are taken unmirrored; the canvas flips them.
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 1,
        height: 1,
        child: Opacity(
          opacity: 0.01,
          child: CameraMacOSView(
            deviceId: widget.feed._deviceId,
            cameraMode: CameraMacOSMode.photo,
            enableAudio: false,
            isVideoMirrored: false,
            resolution: PictureResolution.medium,
            onCameraInizialized: (controller) {
              controller.startImageStream((img) {
                if (img == null) return;
                widget.onFrame(Frame(
                  bytes: img.bytes,
                  width: img.width,
                  height: img.height,
                  stride: img.bytesPerRow,
                  pixelStride: 4,
                  channelOffset: 2, // green ≈ luminance, either byte order
                ));
              });
            },
          ),
        ),
      );
}
