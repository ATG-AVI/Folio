import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart';
import 'package:folio/pages_screen.dart';
import 'package:integration_test/integration_test.dart';

import 'fixtures.dart';

/// Walks every M1 screen and state in light and dark, saving design-review screenshots.
/// Run: fvm flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screenshots_test.dart -d DEVICE
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('design screenshots', (tester) async {
    final root = (await Directory.systemTemp.createTemp('folio')).path;
    final fx = await buildFixtures('$root/base');
    final rendered = await Library.open('$root/base'); // renders every fixture page through the real pipeline
    await rendered.renderIdle();
    await rendered.flush();
    Library? library;
    final lease = fx.docs[0], notes = fx.docs[2];
    const channel = MethodChannel('folio/native');
    void native(Future<Object?> Function(MethodCall)? handler) =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, handler);
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();

    // The last pass is light only, with the system text at 200 % (the PRD's limit) on the three busiest screens.
    for (final (dark, large) in [(false, false), (true, false), (false, true)]) {
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      tester.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
      final tag = '${Platform.operatingSystem}_${dark ? 'dark' : 'light'}';
      Future<void> shot(String name) async {
        await library?.renderIdle(); // capture finished pages, not progress bars
        await tester.pumpAndSettle();
        // Page images decode off the UI thread; give them time before capturing.
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
        }
        await binding.takeScreenshot('${tag}_$name');
      }

      Future<void> tap(Finder f) async {
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      NavigatorState nav() => tester.state<NavigatorState>(find.byType(Navigator).first);
      Future<void> back() async {
        nav().pop();
        await tester.pumpAndSettle();
      }

      if (large) {
        await copyTree('$root/base', '$root/${tag}_large');
        library = await Library.open('$root/${tag}_large');
        await tester.pumpWidget(FolioApp(key: UniqueKey(), library: library));
        await shot('16_large_text_home');
        await tap(find.text(lease.name));
        await shot('17_large_text_review');
        await tap(find.text('Export PDF'));
        await shot('18_large_text_export');
        break;
      }

      await tester.pumpWidget(FolioApp(key: UniqueKey(), library: Library('$root/empty')));
      await shot('01_home_empty');

      await copyTree('$root/base', '$root/$tag');
      library = await Library.open('$root/$tag');
      await tester.pumpWidget(FolioApp(key: UniqueKey(), library: library));
      await shot('02_home');

      var copies = 0; // the ID sheet deletes an abandoned front side, so hand it a fresh copy each time
      native((call) async => call.method == 'scan' ? [File(fx.idFront).copySync('$root/front${copies++}.jpg').path] : null);
      await tap(find.text('ID card'));
      await shot('03_id_card_front');
      await tap(find.text('Scan front'));
      await shot('04_id_card_back');
      await back();

      native((_) async => throw PlatformException(code: 'unavailable')); // an emulator with Play services would open the real scanner
      await tap(find.text('Scan'));
      await shot('05_scanner_unavailable');
      await back();

      native((_) async => throw PlatformException(code: 'denied'));
      await tap(find.text('Scan'));
      await shot('06_camera_denied');
      await back();
      native(null);

      await tap(find.text(lease.name));
      await shot('07_review_pages');

      await tap(find.text('Page 2'));
      await tap(find.text('Enhance'));
      await shot('08_crop_enhance');
      for (var i = 0; i < 2; i++) {
        await tester.fling(find.byType(PageView), const Offset(-600, 0), 2000);
        await tester.pumpAndSettle();
      }
      await tap(find.text('Crop'));
      final corner = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Crop corner, top right');
      // Drag as a "device" pointer so the test binding doesn't paint its debug crosshair into the shot.
      binding.shouldPropagateDevicePointerEvents = true;
      void send(PointerEvent e) => binding.handlePointerEventForSource(e, source: TestBindingEventSource.device);
      var at = tester.getCenter(corner);
      send(PointerDownEvent(pointer: 99, position: at));
      for (var i = 0; i < 8; i++) {
        at += const Offset(-3, 5);
        send(PointerMoveEvent(pointer: 99, position: at, delta: const Offset(-3, 5)));
        await tester.pump();
      }
      await shot('09_crop');
      send(PointerUpEvent(pointer: 99, position: at));
      binding.shouldPropagateDevicePointerEvents = false;
      await back(); // discard crop
      await back(); // leave Crop & Enhance

      await tap(find.text('Export PDF'));
      await shot('10_export');
      await tap(find.text('Preview'));
      await shot('11_preview');
      await back();
      await back();
      await back();

      nav().push(MaterialPageRoute<void>(builder: (_) => PagesScreen(docId: fx.docs[5].id)));
      await tester.pumpAndSettle();
      await tap(find.text('Export PDF'));
      await shot('15_id_card_export'); // A4 · Letter, no Fit
      await tap(find.text('Preview'));
      await shot('12_id_card_preview');
      await back();
      await back();
      await back();

      nav().push(
        MaterialPageRoute<void>(
          builder: (_) => PagesScreen(docId: notes.id, notice: '2 photos couldn’t be added. Their file format isn’t supported.'),
        ),
      );
      await shot('13_review_notice');
      await back();

      library.save(fx.damaged);
      await shot('14_home_damaged');
    }
  });
}
