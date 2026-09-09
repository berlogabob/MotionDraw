import 'package:camera/camera.dart';
import 'package:camera_macos/camera_macos.dart';
import 'package:flutter/material.dart';

import 'camera_strip.dart';

/// A source of camera frames plus its on-screen preview.
abstract class CameraFeed {
  /// Clockwise quarter turns from image space to screen space.
  int get rotationDegrees;

  /// Whether the preview is mirrored relative to the frames.
  bool get mirrored;

  /// The preview widget; starts delivering frames to [onFrame] once live.
  Widget buildPreview(void Function(Frame) onFrame);
}

// ---------------------------------------------------------------- iOS/Android

class MobileCameraFeed implements CameraFeed {
  MobileCameraFeed(this.camera);
  final CameraDescription camera;

  @override
  int get rotationDegrees => camera.sensorOrientation;

  // ponytail: front-camera preview mirroring not handled yet; back camera
  // is the primary use. Flip this per lensDirection if it bites.
  @override
  bool get mirrored => false;

  @override
  Widget buildPreview(void Function(Frame) onFrame) =>
      _MobilePreview(camera: camera, onFrame: onFrame);
}

class _MobilePreview extends StatefulWidget {
  const _MobilePreview({required this.camera, required this.onFrame});
  final CameraDescription camera;
  final void Function(Frame) onFrame;

  @override
  State<_MobilePreview> createState() => _MobilePreviewState();
}

class _MobilePreviewState extends State<_MobilePreview>
    with WidgetsBindingObserver {
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
      ResolutionPreset.low, // motion detection needs no more
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    await controller.startImageStream((img) {
      final y = img.planes[0];
      widget.onFrame(Frame(
        bytes: y.bytes,
        width: img.width,
        height: img.height,
        stride: y.bytesPerRow,
      ));
    });
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
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
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    // Sensor is landscape; swap so the box matches the rotated preview,
    // then cover the frame.
    final ps = controller.value.previewSize!;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: ps.height,
        height: ps.width,
        child: CameraPreview(controller),
      ),
    );
  }
}

// --------------------------------------------------------------------- macOS

class MacCameraFeed implements CameraFeed {
  @override
  int get rotationDegrees => 0;

  // The plugin sets isVideoMirrored on the capture connection, so streamed
  // frames are already mirrored exactly like the preview texture.
  @override
  bool get mirrored => false;

  @override
  Widget buildPreview(void Function(Frame) onFrame) => LayoutBuilder(
        // CameraMacOSView sizes itself to MediaQuery.size (the window) before
        // applying BoxFit.cover; lie about the window size so it covers the
        // frame instead and image coordinates line up with frame coordinates.
        builder: (context, constraints) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: constraints.biggest),
          child: CameraMacOSView(
            cameraMode: CameraMacOSMode.photo,
            enableAudio: false,
            fit: BoxFit.cover,
            resolution: PictureResolution.low,
            onCameraInizialized: (controller) {
              controller.startImageStream((img) {
                if (img == null) return;
                onFrame(Frame(
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
