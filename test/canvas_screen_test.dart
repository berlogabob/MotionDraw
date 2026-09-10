import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motiondraw/camera_strip.dart';
import 'package:motiondraw/canvas_screen.dart';
import 'package:motiondraw/feeds.dart';
import 'package:motiondraw/sampler.dart';

class _FakeFeed implements CameraFeed {
  @override
  int index = 0;
  @override
  int get rotationDegrees => 0;
  @override
  bool get mirrorDefault => false;
  @override
  List<String> get cameras => const ['front', 'back'];
  @override
  Widget host(void Function(Frame) onFrame) => const SizedBox.shrink();
}

void main() {
  testWidgets('two caption lines; hamburger opens the settings sheet',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: CanvasScreen(sampler: Sampler(), feed: _FakeFeed())));
    await tester.pump();

    expect(find.textContaining('MODE'), findsOneWidget);
    expect(find.textContaining('LINE'), findsOneWidget);
    expect(find.textContaining('SCALE'), findsNothing);

    final burger = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == const Size(32, 32));
    expect(burger, findsOneWidget);
    await tester.tap(burger);
    await tester.pump();

    expect(find.textContaining('SCALE'), findsOneWidget);
    expect(find.textContaining('SENS   : 1.00 MID'), findsOneWidget);
    // No frame has arrived in the test, so the camera row reports waiting.
    expect(find.textContaining('CAMERA : WAITING'), findsOneWidget);

    // Drag the track to the right end → MAX.
    final track = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size.height == 16);
    await tester.drag(track, const Offset(2000, 0));
    await tester.pump();
    expect(find.textContaining('4.00 MAX'), findsOneWidget);

    await tester.tap(find.text('CLOSE'));
    await tester.pump();
    expect(find.textContaining('SCALE'), findsNothing);
  });

  testWidgets('caption rows respond when the frame is height-limited',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
        home: CanvasScreen(sampler: Sampler(), feed: _FakeFeed())));
    await tester.pump();
    await tester.tap(find.textContaining('MODE'));
    await tester.pump();
    expect(find.textContaining('MODE   : STATIC'), findsOneWidget);
    await tester.tap(find.textContaining('TEMPO'));
    await tester.pump();
    expect(find.textContaining('TEMPO  : QUANT'), findsOneWidget);
    expect(find.textContaining('BPM    : 120'), findsOneWidget);
    expect(find.textContaining('DIV    : 1/8'), findsOneWidget);
    await tester.tap(find.textContaining('TEMPO'));
    await tester.pump();
    expect(find.textContaining('TEMPO  : SEQ'), findsOneWidget);
    expect(find.textContaining('LEN    : 16'), findsOneWidget);
    await tester.tap(find.textContaining('LEN'));
    await tester.pump();
    expect(find.textContaining('LEN    : 32'), findsOneWidget);
    expect(find.text('CLEAR'), findsOneWidget);
    await tester.tap(find.textContaining('SEQ    : LOOP'));
    await tester.pump();
    expect(find.textContaining('SEQ    : ONCE'), findsOneWidget);
    expect(find.textContaining('LEN'), findsNothing);
  });
}
