import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/document.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';

/// The photo picker, faked: hands back whatever files the test queued.
class FakePicker extends ImagePickerPlatform {
  List<String> next = [];

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async => [
    for (final p in next) XFile(p),
  ];

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async =>
      next.isEmpty ? null : XFile(next.first);
}

/// Import and editing flows on a device: real library, real renders, real files; only the picker is fake.
/// Tests that tap Scan declare the scanner unavailable: an emulator with Play services would open the real one.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final picker = FakePicker();
  ImagePickerPlatform.instance = picker;
  late Directory tmp;
  late Library library;
  var n = 0;

  String photo({bool png = false, int w = 900, int h = 1200}) {
    final im = img.Image(width: w, height: h)..clear(img.ColorRgb8(240, 238, 230));
    img.fillRect(im, x1: w ~/ 8, y1: h ~/ 8, x2: w * 7 ~/ 8, y2: h ~/ 5, color: img.ColorRgb8(30, 30, 40));
    final path = '${tmp.path}/pick${n++}.${png ? 'png' : 'jpg'}';
    File(path).writeAsBytesSync(png ? img.encodePng(im, level: 1) : img.encodeJpg(im, quality: 90));
    return path;
  }

  Future<void> start(WidgetTester tester) async {
    tmp = Directory.systemTemp.createTempSync('folio_editor');
    library = await Library.open('${tmp.path}/library');
    await tester.pumpWidget(FolioApp(key: UniqueKey(), library: library));
    await tester.pumpAndSettle();
  }

  /// Pumps real time until [f] shows (imports and renders run on real isolates).
  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 300 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(f, findsWidgets);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  /// Taps, then lets route transitions and running renders finish (their progress bars animate).
  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  Document only() => library.query('', DocSort.recent).single;

  /// Scan reports "unavailable" (detectCorners finds nothing), so the Import / Take photo fallback is offered.
  void noScanner(WidgetTester tester) {
    const channel = MethodChannel('folio/native');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'scan') throw PlatformException(code: 'unavailable');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  }

  testWidgets('import opens Crop & Enhance, then Review Pages, and reports files it couldn’t use', (tester) async {
    await start(tester);
    final bad = '${tmp.path}/notes.txt';
    File(bad).writeAsStringSync('not a photo');
    picker.next = [photo(), photo(png: true), bad];

    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 2'));
    final d = only();
    expect(d.pages, hasLength(2));
    expect(d.pages.every((p) => p.filter == PageFilter.enhance), isTrue, reason: 'imports start on Enhance');
    expect(picker.next.every((p) => !File(p).existsSync()), isTrue, reason: 'picker copies cleaned up, including the bad one');

    await tap(tester, find.text('Done'));
    await waitFor(tester, find.textContaining('1 photo couldn’t be added'));
    expect(find.text('Page 2'), findsOneWidget);
    await library.renderIdle();
    expect(only().pages.every(only().isRendered), isTrue);
  });

  testWidgets('cancelling an import keeps the pages already added', (tester) async {
    await start(tester);
    picker.next = [for (var i = 0; i < 12; i++) photo(png: true, w: 1500, h: 2000)]; // PNGs: slow enough to cancel midway
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Adding photos'));
    await tap(tester, find.text('Cancel'));
    await waitFor(tester, find.textContaining('Stopped.'));
    final added = only().pages.length;
    expect(added, inInclusiveRange(1, 11));
    expect(find.text('Stopped. $added of 12 added.'), findsOneWidget, reason: 'counts pages added, not files tried');
    await waitFor(tester, find.text('Page 1 of $added'));
  });

  testWidgets('crop clamps handles to the image, blocks a mirrored shape, and saves corners', (tester) async {
    await start(tester);
    picker.next = [photo()];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    await tap(tester, find.text('Crop'));
    await waitFor(tester, find.text('Reset'));
    Finder corner(String name) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Crop corner, $name');
    TextButton done() => tester.widget<TextButton>(find.widgetWithText(TextButton, 'Done'));

    // Dragging the top-left handle past the top-right one mirrors the quad: Done must turn off.
    final tl = tester.getCenter(corner('top left')), tr = tester.getCenter(corner('top right'));
    await tester.dragFrom(tl, Offset(tr.dx - tl.dx + 60, 30));
    await tester.pump();
    expect(done().onPressed, isNull);
    expect(find.text('Corners must make a four-sided shape'), findsOneWidget);

    await tap(tester, find.text('Reset'));
    expect(done().onPressed, isNotNull);
    // Far off the image: the handle stops at the edge.
    await tester.dragFrom(tester.getCenter(corner('bottom right')), const Offset(500, 500));
    await tester.dragFrom(tester.getCenter(corner('top left')), const Offset(40, 40));
    await tester.pump();
    await tap(tester, find.text('Done'));
    final c = only().pages.single.corners!;
    expect([c[4], c[5]], [1.0, 1.0], reason: 'clamped to the image');
    expect(c[0], greaterThan(0));
    expect(c[1], greaterThan(0));
  });

  testWidgets('replace swaps the page image and Undo brings the old one back', (tester) async {
    await start(tester);
    picker.next = [photo()];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    await tap(tester, find.text('Done'));
    final before = only().pages.single;

    picker.next = [photo(w: 700, h: 500)];
    await tap(tester, find.byTooltip('Page options'));
    await tap(tester, find.text('Replace'));
    await waitFor(tester, find.text('Page replaced'));
    expect(only().pages.single.src, isNot(before.src));
    expect(only().pages.single.id, before.id, reason: 'same place in the document');

    await tap(tester, find.text('Undo'));
    expect(only().pages.single.src, before.src);
  });

  testWidgets('two picks with the same name are imported once and the other is reported', (tester) async {
    await start(tester);
    final same = photo();
    picker.next = [same, same]; // what Android returns for two photos both named image.jpg
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    await tap(tester, find.text('Done'));
    await waitFor(tester, find.textContaining('1 photo couldn’t be added'));
  });

  testWidgets('Retake asks the scanner for one page and replaces the page with it', (tester) async {
    await start(tester);
    picker.next = [photo()];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    final scan = photo();
    const channel = MethodChannel('folio/native');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method != 'scan') return null;
      return c.arguments['pageLimit'] == 1 ? [scan] : throw StateError('Retake must pass pageLimit 1');
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tap(tester, find.text('Retake'));
    await waitFor(tester, find.text('Page replaced'));
    expect(only().pages, hasLength(1));
    expect(only().pages.single.filter, PageFilter.original, reason: 'scanner pages are already cleaned up');
    expect(File(scan).existsSync(), isFalse, reason: 'copied into the document, then deleted');
  });

  testWidgets('without a scanner, Take photo starts a new document', (tester) async {
    noScanner(tester);
    await start(tester);
    picker.next = [photo()];
    await tap(tester, find.text('Scan'));
    await waitFor(tester, find.text('Scanner not available here'));
    await tap(tester, find.text('Take photo'));
    await waitFor(tester, find.text('Page 1 of 1'));
    expect(only().kind, DocKind.document);
  });

  testWidgets('ID card: front, then back, becomes one ID-card document', (tester) async {
    noScanner(tester);
    await start(tester);
    await tap(tester, find.text('ID card'));
    picker.next = [photo(w: 1011, h: 638)];
    await tap(tester, find.text('Scan front'));
    await waitFor(tester, find.text('Import photos'));
    await tap(tester, find.text('Import photos'));
    await waitFor(tester, find.text('Now flip the card over'));
    // The back goes straight to the picker: the unavailable-scanner sheet isn't shown a second time.
    picker.next = [photo(w: 1011, h: 638)];
    await tap(tester, find.text('Import back'));
    expect(find.text('Scanner not available here'), findsNothing);
    await waitFor(tester, find.text('Page 1 of 2'));
    expect(only().kind, DocKind.idCard);
    await tap(tester, find.text('Done'));
    await waitFor(tester, find.text('Back'));
    expect(find.text('Front'), findsOneWidget);
  });

  // The real channel, no mock. iPhone only: the Simulator's Vision can't find documents (its first answer is a
  // whole-frame box at confidence 0, later ones the same wrong box at ~0.99), while a Mac finds this sheet exactly.
  testWidgets('iPhone: importing a photo of a page finds its corners', (tester) async {
    // A slightly rotated sheet (corners TL, TR, BR, BL) with text-like lines on a dark desk.
    const w = 900, h = 1200, angle = 0.07;
    img.Point at(double sx, double sy) {
      final x = sx * 315, y = sy * 456;
      return img.Point(w / 2 + x * math.cos(angle) - y * math.sin(angle), h / 2 + x * math.sin(angle) + y * math.cos(angle));
    }

    final im = img.Image(width: w, height: h)..clear(img.ColorRgb8(30, 30, 36));
    img.fillPolygon(im, vertices: [at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)], color: img.ColorRgb8(238, 235, 225));
    for (var i = 0; i < 5; i++) {
      final y = -0.6 + i * 0.3;
      img.fillPolygon(im, vertices: [at(-0.7, y), at(0.7, y), at(0.7, y + 0.06), at(-0.7, y + 0.06)], color: img.ColorRgb8(40, 40, 50));
    }
    final want = [
      for (final p in [at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)]) ...[p.x / w, p.y / h],
    ];
    final path = '${Directory.systemTemp.createTempSync('folio_vision').path}/sheet.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(im, quality: 95));

    await start(tester);
    picker.next = [path];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    final got = only().pages.single.corners;
    expect(got, isNotNull, reason: 'Vision found the sheet');
    for (final (i, v) in got!.indexed) {
      expect(v, closeTo(want[i], 0.06), reason: 'corner value $i');
    }
  }, skip: !Platform.isIOS || Directory.systemTemp.path.contains('/CoreSimulator/')); // the app's container is there on the Simulator
}
