import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/document.dart';
import 'package:folio/export_sheet.dart';
import 'package:folio/id_card_sheet.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart';
import 'package:folio/ocr.dart' show clearTextCache;
import 'package:folio/pdf.dart';
import 'package:folio/ui.dart' show PageImage;
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';

import 'flate.dart';

final root = Directory.systemTemp.createTempSync('folio_widgets').path;

/// Pages count as already rendered, so no background render starts inside these fake-async tests.
Document doc(String name, List<String> pageIds, {Duration ago = Duration.zero, DocKind kind = DocKind.document}) {
  final at = DateTime(2026, 10, 27).subtract(ago);
  final id = newId();
  final d = Document(
    id: id,
    dir: '$root/$id',
    name: name,
    kind: kind,
    createdAt: at,
    updatedAt: at,
    pages: [for (final id in pageIds) DocPage(id: id, src: 'src/$id.jpg', w: 1240, h: 1754)],
  );
  return d.copyWith(pages: [for (final p in d.pages) p.copyWith(r: d.renderKey(p))]);
}

/// [doc] with a real (tiny) JPEG at each page's render path, so buildPdf has something to embed.
Document exportable(String name, List<String> pageIds) {
  final d = doc(name, pageIds);
  for (final p in d.pages) {
    File('${d.dir}/${p.renderPath}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 31, height: 44)));
  }
  return d;
}

/// Share and Print as printing's platform interface sees them.
class _FakePrinting extends PrintingPlatform {
  ({Uint8List bytes, String name, Rect bounds})? shared;
  ({Uint8List bytes, String name})? printed;

  /// Thrown before the dialog asks for the pages (no printing service, say).
  Object? failFirst;

  /// What the print job does once the dialog has the pages. On Android layoutPdf waits for all of it.
  Future<bool> Function() job = () async => true;

  @override
  Future<bool> sharePdf(Uint8List bytes, String filename, Rect bounds, String? subject, String? body, List<String>? emails) async {
    shared = (bytes: bytes, name: filename, bounds: bounds);
    return true;
  }

  @override
  Future<bool> layoutPdf(
    Printer? printer,
    LayoutCallback onLayout,
    String name,
    PdfPageFormat format,
    bool dynamicLayout,
    bool usePrinterSettings,
    OutputType outputType,
    bool forceCustomPrintPaper,
    bool windowsModernDialog,
  ) async {
    if (failFirst != null) throw failFirst!;
    printed = (bytes: await onLayout(format), name: name);
    return job();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A library that notes which documents were asked to render everything (`rendered`).
class _SpyLibrary extends Library {
  _SpyLibrary(super.root, {super.docs});

  final asked = <String>[];

  @override
  Future<Document?> rendered(String id) {
    asked.add(id);
    return super.rendered(id);
  }
}

/// The photo picker: hands back the queued files in order and notes where each pick was asked for.
class _FakePicker extends ImagePickerPlatform {
  final queue = <String>[];
  final sources = <ImageSource>[];

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    sources.add(source);
    return XFile(queue.removeAt(0));
  }
}

/// The platform side of an export: where "temp" is, what the save picker is asked, and what it answers.
class _Platform {
  _Platform(WidgetTester tester) : sandbox = Directory.systemTemp.createTempSync('folio_export') {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => sandbox.path);
    messenger.setMockMethodCallHandler(const MethodChannel('folio/native'), (call) async {
      final path = call.arguments['path'] as String;
      if (call.method == 'recognizeText') {
        asked.add(path);
        return ocr(path);
      }
      // Read now: the sheet deletes the file as soon as the picker is done.
      saves.add((path: path, name: call.arguments['name'] as String, bytes: File(path).readAsBytesSync()));
      return reply();
    });
    final printing = PrintingPlatform.instance;
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('folio/native'), null);
      PrintingPlatform.instance = printing;
      sandbox.deleteSync(recursive: true);
    });
  }

  final Directory sandbox;

  /// The text recogniser: what it answers for a render's path (default: none on this device), and the paths it was asked.
  Future<Object?> Function(String path) ocr = (_) async => throw PlatformException(code: 'unavailable');
  final asked = <String>[];
  final saves = <({String path, String name, Uint8List bytes})>[];
  Future<Object?> Function() reply = () async => true;
  final printing = _FakePrinting();

  /// Replaces printing's real platform with [printing] until the test ends.
  void fakePrinting() => PrintingPlatform.instance = printing;

  bool get tempFolderEmpty => !Directory('${sandbox.path}/folio').existsSync() || Directory('${sandbox.path}/folio').listSync().isEmpty;
}

/// What the recogniser finds on a page: one line.
List<Object?> lines(String text) => [
  {
    'text': text,
    'box': [0.1, 0.1, 0.8, 0.15],
  },
];

/// The system clipboard, faked: [text] is what was last copied.
class _Clipboard {
  _Clipboard(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') text = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  String? text;
}

/// Opens page [i]'s menu on Review Pages and taps "Copy text" (the answer is whatever the fake recogniser gives).
Future<void> tapCopy(WidgetTester tester, int i) async {
  await tester.tap(find.byTooltip('Page options').at(i));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Copy text'));
  await tester.pump();
}

/// Lets real isolates and file I/O run, rebuilding as it goes, until [done].
Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: 'timed out');
}

ButtonStyleButton button(WidgetTester tester, String label) =>
    tester.widget(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first);

/// Opens the export sheet from the document's menu on Home. With the Searchable text switch the sheet is taller than
/// the default 800x600 test surface (Save would sit below the fold), so [tall] gives it room.
Future<void> openExport(WidgetTester tester, Library library, Document d, {bool tall = true}) async {
  if (tall) {
    tester.view
      ..physicalSize = const Size(800, 900) * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(FolioApp(library: library));
  final menu = find.byTooltip('Options for ${d.name}');
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Export PDF'));
  await tester.pumpAndSettle();
  expect(find.byType(ExportSheet), findsOneWidget);
}

final nameField = find.descendant(of: find.byType(ExportSheet), matching: find.byType(TextField));

/// Every control of the sheet is on or off together.
void expectControls(WidgetTester tester, {required bool enabled}) {
  for (final label in ['Share', 'Save to device', 'Print', 'Preview']) {
    expect(button(tester, label).onPressed != null, enabled, reason: label);
  }
  expect(tester.widget<TextField>(nameField).enabled, enabled, reason: 'file name');
  expect(
    tester.widget<SegmentedButton<Quality>>(find.byType(SegmentedButton<Quality>)).onSelectionChanged != null,
    enabled,
    reason: 'quality',
  );
  expect(
    tester.widget<SegmentedButton<PageSize>>(find.byType(SegmentedButton<PageSize>)).onSelectionChanged != null,
    enabled,
    reason: 'page size',
  );
  expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged != null, enabled, reason: 'searchable text');
}

void main() {
  // capturePages' guard is global: a test that ends with a scanner sheet still open would leave it set.
  setUp(() => scanning.value = false);
  setUp(clearTextCache);

  testWidgets('empty library invites a first scan', (tester) async {
    await tester.pumpWidget(FolioApp(library: Library(root)));
    expect(find.text('No documents yet'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
  });

  testWidgets('home lists, searches and opens documents', (tester) async {
    await tester.pumpWidget(
      FolioApp(
        library: Library(
          root,
          docs: [
            doc('Lease agreement', ['a', 'b', 'c']),
            doc('Grocery receipt', ['r'], ago: const Duration(days: 1)),
          ],
        ),
      ),
    );
    expect(find.text('Lease agreement'), findsOneWidget);
    expect(find.textContaining('3 pages'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'RECEIPT');
    await tester.pump();
    expect(find.text('Lease agreement'), findsNothing);
    expect(find.text('Grocery receipt'), findsOneWidget);

    await tester.tap(find.text('Grocery receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Export PDF'), findsOneWidget);
  });

  testWidgets('scan without a native scanner explains and offers import', (tester) async {
    // Same reply the engine gives when no platform code handles the channel.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('folio/native'),
      (_) => throw MissingPluginException(),
    );
    await tester.pumpWidget(FolioApp(library: Library(root)));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Scanner not available here'), findsOneWidget);
    expect(find.text('Import photos'), findsOneWidget);
  });

  testWidgets('undo puts back only the deleted page and keeps later edits', (tester) async {
    final d = doc('Notes', ['a', 'b']);
    final library = Library(root, docs: [d]);
    await tester.pumpWidget(FolioApp(library: library));
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Page options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(library.byId(d.id)!.pages.map((p) => p.id), ['b']);

    library.save(library.byId(d.id)!.copyWith(name: 'Renamed later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(library.byId(d.id)!.pages.map((p) => p.id), ['a', 'b']);
    expect(library.byId(d.id)!.name, 'Renamed later');
  });

  testWidgets('rename saves the new name', (tester) async {
    final d = doc('Scan 1', ['a']);
    final library = Library(root, docs: [d]);
    await tester.pumpWidget(FolioApp(library: library));
    await tester.tap(find.text('Scan 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Tax return');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(library.byId(d.id)!.name, 'Tax return');
    expect(find.text('Tax return'), findsOneWidget);
  });

  testWidgets('dragging a page reorders the document and the export the same way', (tester) async {
    final d = doc('Contract', ['a', 'b', 'c']);
    final library = Library(root, docs: [d]);
    await tester.pumpWidget(FolioApp(library: library));
    await tester.tap(find.text('Contract'));
    await tester.pumpAndSettle();

    final handles = find.byIcon(Icons.drag_indicator);
    final step = tester.getCenter(handles.at(1)).dy - tester.getCenter(handles.first).dy; // one card down
    final drag = await tester.startGesture(tester.getCenter(handles.first));
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(Offset(0, (step + 10) / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();

    final now = library.byId(d.id)!;
    expect(now.pages.map((p) => p.id), ['b', 'a', 'c']);
    expect([for (final page in layout(now)) page.images.single.$1.id], ['b', 'a', 'c'], reason: 'the PDF follows the screen');
  });

  group('ID card sheet', () {
    // PRD I1: with no scanner the user picks front and back from the gallery. The problem sheet explains
    // once, for the front; the back then goes straight to the same picker.
    for (final (front, back, from) in [
      ('Import photos', 'Import back', ImageSource.gallery),
      ('Take photo', 'Take photo of back', ImageSource.camera),
    ]) {
      testWidgets('without a scanner: "$front" for the front, then "$back" without the problem sheet', (tester) async {
        final dir = Directory.systemTemp.createTempSync('folio_id');
        final picker = _FakePicker();
        final previous = ImagePickerPlatform.instance;
        ImagePickerPlatform.instance = picker;
        var scans = 0;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(const MethodChannel('folio/native'), (call) async {
          if (call.method == 'scan') scans++;
          throw PlatformException(code: 'unavailable');
        });
        addTearDown(() {
          ImagePickerPlatform.instance = previous;
          messenger.setMockMethodCallHandler(const MethodChannel('folio/native'), null);
          dir.deleteSync(recursive: true);
        });
        picker.queue.addAll([
          for (final n in ['front', 'back'])
            (File('${dir.path}/$n.jpg')..writeAsBytesSync(img.encodeJpg(img.Image(width: 31, height: 20)))).path,
        ]);
        Captured? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showModalBottomSheet<Captured>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const IdCardSheet(),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Scan front'));
        await tester.pumpAndSettle();
        expect(find.text('Scanner not available here'), findsOneWidget);
        await tester.tap(find.text(front));
        await until(tester, () => find.text(back).evaluate().isNotEmpty); // the front is renamed on real disk first
        await tester.pumpAndSettle(); // the problem sheet finishes closing
        expect(find.text('Scanner not available here'), findsNothing);

        await tester.tap(find.text(back));
        await tester.pump();
        expect(find.text('Scanner not available here'), findsNothing, reason: 'the back reuses the front’s choice');
        await until(tester, () => result != null);

        expect(scans, 1, reason: 'the scanner is only tried for the front');
        expect(picker.sources, [from, from]);
        expect(result!.paths, hasLength(2));
        expect(result!.source, front == 'Import photos' ? Source.photos : Source.camera);
      });
    }
  });

  group('export sheet', () {
    testWidgets('Save to device hands a PDF named after the document to the picker, deletes the temp file and reports the size', (
      tester,
    ) async {
      final d = exportable('Tax return', ['a', 'b']);
      final platform = _Platform(tester);
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      await tester.pumpAndSettle();

      final save = platform.saves.single;
      expect(save.name, 'Tax return.pdf');
      expect(save.path, '${platform.sandbox.path}/folio/Tax return.pdf', reason: 'the picker exports the file under its own name on iOS');
      expect(String.fromCharCodes(save.bytes.take(5)), '%PDF-');
      expect(platform.tempFolderEmpty, isTrue);
      expect(find.text('Saved · ${sizeText(save.bytes.length)}'), findsOneWidget);
    });

    testWidgets('an ID card offers A4 and Letter only, shows Fit as A4, and saves the choice', (tester) async {
      final d = doc('Passport', ['f', 'b'], kind: DocKind.idCard); // starts on Fit
      final library = Library(root, docs: [d]);
      await openExport(tester, library, d);

      final sizes = find.byType(SegmentedButton<PageSize>);
      for (final (label, count) in [('Fit', 0), ('A4', 1), ('Letter', 1)]) {
        expect(
          find.descendant(of: sizes, matching: find.text(label)),
          findsNWidgets(count),
          reason: label,
        );
      }
      expect(tester.widget<SegmentedButton<PageSize>>(sizes).selected, {PageSize.a4});

      await tester.tap(find.text('Letter'));
      await tester.pumpAndSettle();
      expect(library.byId(d.id)!.pageSize, PageSize.letter);
      expect(tester.widget<SegmentedButton<PageSize>>(sizes).selected, {PageSize.letter});
    });

    testWidgets('a document still offers Fit, A4 and Letter', (tester) async {
      final d = doc('Tax return', ['a']);
      await openExport(tester, Library(root, docs: [d]), d);
      for (final label in ['Fit', 'A4', 'Letter']) {
        expect(
          find.descendant(of: find.byType(SegmentedButton<PageSize>), matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
    });

    testWidgets('a cancelled picker keeps the sheet open and usable', (tester) async {
      final d = exportable('Tax return', ['a']);
      final platform = _Platform(tester)..reply = () async => false;
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.tap(find.text('Save to device'));
      await until(tester, () => platform.saves.isNotEmpty && find.text('Preparing PDF…').evaluate().isEmpty);

      expect(find.byType(ExportSheet), findsOneWidget);
      expectControls(tester, enabled: true);
      expect(find.textContaining('Couldn’t'), findsNothing);
      expect(find.textContaining('Saved'), findsNothing);
      expect(platform.tempFolderEmpty, isTrue);
    });

    testWidgets('a failed save shows an error in the sheet and re-enables everything', (tester) async {
      final semantics = tester.ensureSemantics();
      final d = exportable('Tax return', ['a']);
      final platform = _Platform(tester)..reply = () async => throw PlatformException(code: 'failed');
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.text('Couldn’t export the PDF. Try again.').evaluate().isNotEmpty);

      expectControls(tester, enabled: true);
      expect(
        tester.widget<Text>(find.text('Couldn’t export the PDF. Try again.')).style!.color,
        Theme.of(tester.element(find.byType(ExportSheet))).colorScheme.error,
      );
      // Announced when it appears: focus doesn't move to it.
      expect(tester.getSemantics(find.text('Couldn’t export the PDF. Try again.')), isSemantics(isLiveRegion: true));
      expect(platform.tempFolderEmpty, isTrue);

      platform.reply = () async => true; // Retry is just pressing the button again
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      expect(platform.saves, hasLength(2));
      semantics.dispose();
    });

    for (final label in ['Save to device', 'Share', 'Print']) {
      testWidgets('$label: everything is disabled while exporting, and Cancel discards the result', (tester) async {
        final semantics = tester.ensureSemantics();
        final d = exportable('Tax return', ['a', 'b']);
        final platform = _Platform(tester)..fakePrinting();
        await openExport(tester, Library(root, docs: [d]), d);

        await tester.tap(find.text(label));
        await tester.pump();
        expect(find.text('Preparing PDF…'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.getSemantics(find.text('Preparing PDF…')), isSemantics(isLiveRegion: true)); // announced: focus doesn't move
        expectControls(tester, enabled: false);

        await tester.tap(find.text('Cancel'));
        await tester.pump();
        expect(find.text('Preparing PDF…'), findsNothing);
        expectControls(tester, enabled: true);

        // The PDF is still being built in its isolate. It finishes, is dropped, and nothing happens.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump();
        expect([platform.saves, platform.printing.shared, platform.printing.printed], [isEmpty, isNull, isNull]);
        expect(platform.tempFolderEmpty, isTrue);
        expect(find.byType(ExportSheet), findsOneWidget);
        expect(find.textContaining('Saved'), findsNothing);
        expectControls(tester, enabled: true);
        semantics.dispose();
      });
    }

    testWidgets('Share passes the PDF, the sanitised file name and the Share button’s rect', (tester) async {
      final d = exportable('Tax return', ['a', 'b']);
      final platform = _Platform(tester)..fakePrinting();
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.enterText(nameField, 'Q3/Q4: report');
      final share = tester.getRect(find.ancestor(of: find.text('Share'), matching: find.bySubtype<ButtonStyleButton>()).first);
      await tester.tap(find.text('Share'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);

      final shared = platform.printing.shared!;
      expect(shared.name, 'Q3-Q4- report.pdf');
      expect(String.fromCharCodes(shared.bytes.take(5)), '%PDF-');
      expect(shared.bounds, share);
      expect(platform.saves, isEmpty);
    });

    testWidgets('Print passes the same PDF to the system print dialog', (tester) async {
      final d = exportable('Tax return', ['a']);
      final platform = _Platform(tester)..fakePrinting();
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.tap(find.text('Print'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);

      expect(platform.printing.printed!.name, 'Tax return.pdf');
      expect(String.fromCharCodes(platform.printing.printed!.bytes.take(5)), '%PDF-');
    });

    for (final (label, job) in <(String, Future<bool> Function())>[
      ('is still going', () => Completer<bool>().future),
      (
        'fails later, as for an offline printer',
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          throw PlatformException(code: 'offline');
        },
      ),
    ]) {
      testWidgets('Print closes the sheet once the dialog has the pages, though the print job $label', (tester) async {
        final d = exportable('Tax return', ['a']);
        final platform = _Platform(tester)..fakePrinting();
        platform.printing.job = job;
        await openExport(tester, Library(root, docs: [d]), d);

        await tester.tap(find.text('Print'));
        await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
        await tester.pump(const Duration(seconds: 1)); // a late failure arrives now, with nobody left to show it to

        expect(platform.printing.printed!.name, 'Tax return.pdf');
        expect(find.textContaining('Couldn’t'), findsNothing);
      });
    }

    testWidgets('Print that fails before the dialog has the pages shows the error and can be retried', (tester) async {
      final d = exportable('Tax return', ['a']);
      final platform = _Platform(tester)..fakePrinting();
      platform.printing.failFirst = PlatformException(code: 'no-printing');
      await openExport(tester, Library(root, docs: [d]), d);

      await tester.tap(find.text('Print'));
      await until(tester, () => find.text('Couldn’t export the PDF. Try again.').evaluate().isNotEmpty);
      expectControls(tester, enabled: true);
      expect(platform.printing.printed, isNull);

      platform.printing.failFirst = null;
      await tester.tap(find.text('Print'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      expect(platform.printing.printed, isNotNull);
    });

    for (final label in ['Save to device', 'Share', 'Print']) {
      testWidgets('$label: closing the sheet while the PDF builds does nothing, and the screen below stays', (tester) async {
        final d = exportable('Tax return', ['a', 'b']);
        final platform = _Platform(tester)..fakePrinting();
        await openExport(tester, Library(root, docs: [d]), d);

        await tester.tap(find.text(label));
        await tester.pump();
        Navigator.of(tester.element(find.byType(ExportSheet))).pop(); // a drag, back and the barrier all end up here
        // The closed sheet animates out for ~200 ms and stays mounted. Real time passes, the fake clock doesn't:
        // the PDF finishes inside that window, which is what used to export and then pop the screen below.
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        expect(find.byType(ExportSheet), findsOneWidget, reason: 'still mounted, so only the route tells that it is closed');
        expect([platform.saves, platform.printing.shared, platform.printing.printed], [isEmpty, isNull, isNull]);

        await tester.pumpAndSettle();
        expect(find.byType(ExportSheet), findsNothing);
        expect(find.text('Tax return'), findsOneWidget, reason: 'Home is still there');
        expect(find.textContaining('Saved'), findsNothing);
        expect(platform.tempFolderEmpty, isTrue);
      });
    }

    testWidgets('a page that failed to render stops the export with a message', (tester) async {
      final d = exportable('Tax return', ['a', 'b']);
      final stale = d.updatePage(1, d.pages[1].copyWith(filter: PageFilter.bw)); // edited, so its render is outdated
      final platform = _Platform(tester);
      await openExport(tester, Library(root, docs: [stale]), stale);

      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.text('Some pages couldn’t be prepared. Try again.').evaluate().isNotEmpty);

      expectControls(tester, enabled: true);
      expect(platform.saves, isEmpty);
    });
  });

  group('searchable text', () {
    final switchTile = find.byType(SwitchListTile);

    /// Opens the export sheet of a two-page document asking for a text layer (or not).
    Future<(_Platform, Document)> open(WidgetTester tester, {bool searchable = true, List<String> pages = const ['a', 'b']}) async {
      final d = exportable('Tax return', pages).copyWith(searchable: searchable);
      final platform = _Platform(tester)..ocr = (path) async => lines('Text of ${path.split('/').last}');
      await openExport(tester, Library(root, docs: [d]), d);
      return (platform, d);
    }

    String body(_Platform p) => inflated(p.saves.single.bytes);

    testWidgets('the switch is off by default, shows its explanation and saves the choice like the other controls', (tester) async {
      final d = exportable('Tax return', ['a']);
      final library = Library(root, docs: [d]);
      await openExport(tester, library, d);

      expect(find.text('Searchable text'), findsOneWidget);
      expect(find.text('Adds hidden text so the PDF can be searched and copied.'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
      await tester.tap(switchTile);
      await tester.pumpAndSettle();
      expect(library.byId(d.id)!.searchable, isTrue);
      expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
      await tester.tap(switchTile);
      await tester.pumpAndSettle();
      expect(library.byId(d.id)!.searchable, isFalse);
    });

    testWidgets('off: nothing is read and the PDF has no text layer', (tester) async {
      final (platform, _) = await open(tester, searchable: false);
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(platform.asked, isEmpty);
      expect(body(platform), isNot(contains(' Tr')));
      expect(find.text('Saved · ${sizeText(platform.saves.single.bytes.length)}'), findsOneWidget);
    });

    testWidgets('on: each page’s render is read in order, the PDF carries the text, and the snackbar stays plain', (tester) async {
      final (platform, d) = await open(tester);
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(platform.asked, [for (final p in d.pages) d.pathOf(p)], reason: 'the renders, in page order');
      expect(RegExp(' 3 Tr').allMatches(body(platform)), hasLength(2), reason: 'one invisible line per page');
      expect(find.text('Saved · ${sizeText(platform.saves.single.bytes.length)}'), findsOneWidget);
      expect(find.textContaining('without'), findsNothing);
    });

    testWidgets('on: a duplicated page is read once, and the lines are reused by the next export in the session', (tester) async {
      final one = exportable('Tax return', ['a']);
      final d = one.duplicatePage(0).copyWith(searchable: true);
      final platform = _Platform(tester);
      platform.ocr = (_) async => lines('Hello');
      platform.reply = () async => false; // the picker is cancelled, so the sheet stays and can export again
      await openExport(tester, Library(root, docs: [d]), d);

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Save to device'));
        await until(tester, () => platform.saves.length == i + 1 && find.text('Preparing PDF…').evaluate().isEmpty);
      }
      expect(platform.asked, [d.pathOf(d.pages[0])], reason: 'two pages, two exports, one read');
      expect(RegExp(' 3 Tr').allMatches(inflated(platform.saves.last.bytes)), hasLength(2), reason: 'both pages carry the text');
    });

    testWidgets('on: shows "Reading text…" while pages are read, Cancel works between pages, and nothing is saved', (tester) async {
      final semantics = tester.ensureSemantics();
      final (platform, d) = await open(tester);
      final first = Completer<Object?>();
      platform.ocr = (path) => path == d.pathOf(d.pages[0]) ? first.future : Future.value(lines('Second'));
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.text('Reading text…').evaluate().isNotEmpty);

      expect(find.text('Preparing PDF…'), findsNothing);
      expect(tester.getSemantics(find.text('Reading text…')), isSemantics(isLiveRegion: true));
      expectControls(tester, enabled: false);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expectControls(tester, enabled: true);

      first.complete(lines('First')); // the page in flight finishes; the next one is never started
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(platform.asked, [d.pathOf(d.pages[0])]);
      expect(platform.saves, isEmpty);
      expect(find.byType(ExportSheet), findsOneWidget);
      semantics.dispose();
    });

    for (final (why, fail) in <(String, Future<Object?> Function(String))>[
      ('no recogniser here (unavailable)', (_) async => throw PlatformException(code: 'unavailable')),
      ('the read failed', (_) async => throw PlatformException(code: 'failed')),
      ('an unreadable answer', (_) async => 'not a list'),
      ('no text anywhere', (_) async => <Object?>[]),
    ]) {
      testWidgets('on, but $why: the PDF still saves, without text, and the snackbar says so', (tester) async {
        final (platform, d) = await open(tester);
        platform.ocr = fail;
        await tester.tap(find.text('Save to device'));
        await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
        await tester.pumpAndSettle();

        expect(platform.asked, hasLength(d.pages.length), reason: 'every page was tried');
        expect(String.fromCharCodes(platform.saves.single.bytes.take(5)), '%PDF-');
        expect(body(platform), isNot(contains(' Tr')));
        expect(find.text('Saved · ${sizeText(platform.saves.single.bytes.length)} · without searchable text'), findsOneWidget);
      });
    }

    testWidgets('on: one page with text is enough for a text layer, and a page that hangs only loses its own text', (tester) async {
      final previous = ocrTimeout;
      ocrTimeout = const Duration(milliseconds: 100);
      addTearDown(() => ocrTimeout = previous);
      final (platform, d) = await open(tester);
      platform.ocr = (path) => path == d.pathOf(d.pages[0]) ? Completer<Object?>().future : Future.value(lines('Second'));
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(RegExp(' 3 Tr').allMatches(body(platform)), hasLength(1));
      expect(find.text('Saved · ${sizeText(platform.saves.single.bytes.length)}'), findsOneWidget);
    });

    testWidgets('on, and every page hangs: the export waits a timeout per page, then saves without text', (tester) async {
      final previous = ocrTimeout;
      ocrTimeout = const Duration(milliseconds: 100);
      addTearDown(() => ocrTimeout = previous);
      final (platform, _) = await open(tester);
      platform.ocr = (_) => Completer<Object?>().future;
      await tester.tap(find.text('Save to device'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      await tester.pumpAndSettle();

      expect(platform.asked, hasLength(2));
      expect(find.textContaining('without searchable text'), findsOneWidget);
    });

    for (final label in ['Share', 'Print']) {
      testWidgets('$label with a failing recogniser exports without text and stays silent about it', (tester) async {
        final (platform, _) = await open(tester);
        platform.fakePrinting();
        platform.ocr = (_) async => throw PlatformException(code: 'unavailable');
        await tester.tap(find.text(label));
        await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
        await tester.pumpAndSettle();

        final bytes = (label == 'Share' ? platform.printing.shared?.bytes : platform.printing.printed?.bytes)!;
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(inflated(bytes), isNot(contains(' Tr')));
        expect(find.textContaining('without'), findsNothing);
      });
    }

    testWidgets('Share with a working recogniser hands over the text layer', (tester) async {
      final (platform, _) = await open(tester);
      platform
        ..fakePrinting()
        ..ocr = (_) async => lines('Hello');
      await tester.tap(find.text('Share'));
      await until(tester, () => find.byType(ExportSheet).evaluate().isEmpty);
      expect(RegExp(' 3 Tr').allMatches(inflated(platform.printing.shared!.bytes)), hasLength(2));
    });
  });

  group('Copy text', () {
    /// Review Pages of a two-page document, with a fake recogniser (the text is named after the render file) and clipboard.
    Future<(_Platform, _Clipboard, Document)> reviewPages(WidgetTester tester, {Document? doc, Library? library}) async {
      final d = doc ?? exportable('Tax return', ['a', 'b']);
      final platform = _Platform(tester)..ocr = (path) async => lines('Text of ${path.split('/').last}');
      final clipboard = _Clipboard(tester);
      await tester.pumpWidget(FolioApp(library: library ?? Library(root, docs: [d])));
      await tester.tap(find.text('Tax return'));
      await tester.pumpAndSettle();
      return (platform, clipboard, d);
    }

    Future<void> shows(WidgetTester tester, String message) => until(tester, () => find.text(message).evaluate().isNotEmpty);

    testWidgets('puts the page’s lines on the clipboard, one per line, read from that page’s render', (tester) async {
      final (platform, clipboard, d) = await reviewPages(tester);
      await tapCopy(tester, 0);
      await shows(tester, 'Text copied');
      expect(clipboard.text, 'Text of ${d.pages[0].renderPath!.split('/').last}');

      platform.ocr = (_) async => [...lines('First line'), ...lines('Second line')];
      await tapCopy(tester, 1);
      await shows(tester, 'Text copied');
      expect(clipboard.text, 'First line\nSecond line');
      expect(platform.asked, [d.pathOf(d.pages[0]), d.pathOf(d.pages[1])]);
      expect(platform.asked.last, contains('/cache/'), reason: 'the render, not the source image');
    });

    testWidgets('says so when the page has no text, and copies nothing', (tester) async {
      final (platform, clipboard, _) = await reviewPages(tester);
      platform.ocr = (_) async => <Object?>[];
      await tapCopy(tester, 0);
      await shows(tester, 'No text found on this page');
      expect(clipboard.text, isNull);
    });

    for (final code in ['unavailable', 'failed']) {
      testWidgets('says the recogniser isn’t available right now when native answers $code, copies nothing, and can be retried', (
        tester,
      ) async {
        final (platform, clipboard, _) = await reviewPages(tester);
        platform.ocr = (_) async => throw PlatformException(code: code);
        await tapCopy(tester, 0);
        await shows(tester, 'Text recognition isn’t available right now. Try again in a minute.');
        expect(clipboard.text, isNull);

        platform.ocr = (_) async => lines('Now it works'); // the failure was not remembered
        await tapCopy(tester, 0);
        await shows(tester, 'Text copied');
        expect(clipboard.text, 'Now it works');
      });
    }

    testWidgets('a page whose render is current is read at once: nothing waits for the document’s render queue', (tester) async {
      final d = exportable('Tax return', ['a', 'b']);
      final library = _SpyLibrary(root, docs: [d]);
      final (_, clipboard, _) = await reviewPages(tester, doc: d, library: library);
      await tapCopy(tester, 0);
      await shows(tester, 'Text copied');
      expect(clipboard.text, isNotNull);
      expect(library.asked, isEmpty, reason: 'rendered() would have waited for every page of the document');
    });

    testWidgets('a page whose render file is gone is rendered again first, then read', (tester) async {
      final d = doc('Tax return', ['a']);
      File('${d.dir}/src/a.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 31, height: 44)));
      final library = _SpyLibrary(root, docs: [d]); // marked rendered, but cache/ has no file
      final (platform, clipboard, _) = await reviewPages(tester, doc: d, library: library);
      await tapCopy(tester, 0);
      await shows(tester, 'Text copied');
      expect(library.asked, [d.id]);
      expect(platform.asked, [d.pathOf(d.pages.single)]);
      expect(File(platform.asked.single).existsSync(), isTrue);
      expect(clipboard.text, isNotNull);
    });

    testWidgets('a page whose render fails says it couldn’t be prepared, not that recognition is down, and reads nothing', (tester) async {
      final d = doc('Tax return', ['a']); // no source file either: the render can only fail
      final library = _SpyLibrary(root, docs: [d]);
      final (platform, clipboard, _) = await reviewPages(tester, doc: d, library: library);
      await tapCopy(tester, 0);
      await shows(tester, 'This page couldn’t be prepared. Edit it or try again.');
      expect(find.text('Text recognition isn’t available right now. Try again in a minute.'), findsNothing);
      expect(library.asked, [d.id]);
      expect(platform.asked, isEmpty);
      expect(clipboard.text, isNull);
    });

    testWidgets('a slow read says "Reading text…" after a moment, then the result replaces it', (tester) async {
      final (platform, clipboard, _) = await reviewPages(tester);
      final answer = Completer<Object?>();
      platform.ocr = (_) => answer.future;
      await tapCopy(tester, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reading text…'), findsNothing, reason: 'a quick read shows nothing in between');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Reading text…'), findsOneWidget);

      answer.complete(lines('Slow text'));
      await shows(tester, 'Text copied');
      expect(find.text('Reading text…'), findsNothing);
      expect(clipboard.text, 'Slow text');
    });
  });

  group('accessibility', () {
    // Real Roboto, not the test font Ahem (every glyph a full-em square), so 200 % text wraps as on a phone.
    // Last group in the file, so no other test sees the font.
    setUpAll(() async {
      final loader = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        final file = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/Roboto-$weight.ttf');
        loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
      }
      await loader.load();
    });

    /// Each screen as a user reaches it.
    late final Map<String, Future<void> Function(WidgetTester)> screens;
    screens = <String, Future<void> Function(WidgetTester)>{
      'Home, empty': (t) => t.pumpWidget(FolioApp(library: Library(root))),
      'Home': (t) => t.pumpWidget(FolioApp(library: Library(root, docs: _library()))),
      'Review Pages': (t) async {
        await t.pumpWidget(FolioApp(library: Library(root, docs: _library())));
        await t.ensureVisible(find.text('Lease agreement')); // a landscape phone shows one row of tiles
        await t.pumpAndSettle();
        await t.tap(find.text('Lease agreement'));
      },
      'Crop & Enhance': (t) async {
        await screens['Review Pages']!(t);
        await t.pumpAndSettle();
        await t.tap(find.text('Page 1'));
      },
      'Crop': (t) async {
        final d = _library().first;
        File('${d.dir}/src/a.jpg')
          ..createSync(recursive: true)
          ..writeAsBytesSync(img.encodeJpg(img.Image(width: 62, height: 88)));
        await t.pumpWidget(FolioApp(library: Library(root, docs: [d])));
        await t.ensureVisible(find.text('Lease agreement'));
        await t.pumpAndSettle();
        await t.tap(find.text('Lease agreement'));
        await t.pumpAndSettle();
        await t.tap(find.text('Page 1'));
        await t.pumpAndSettle();
        await t.tap(find.text('Crop'));
        await until(t, () => find.bySemanticsLabel('Crop corner, top left').evaluate().isNotEmpty); // the image size is read in an isolate
      },
      'Export sheet': (t) async {
        final d = _library().first;
        await openExport(t, Library(root, docs: [d]), d, tall: false); // `phone()` has set the size
      },
      'Preview': (t) async {
        final d = _library().first;
        await openExport(t, Library(root, docs: [d]), d, tall: false); // `phone()` has set the size
        await t.tap(find.text('Preview'));
      },
      'ID sheet': (t) async {
        await t.pumpWidget(FolioApp(library: Library(root)));
        await t.tap(find.text('ID card'));
      },
    };

    /// A 390x844 phone (or [size]), with the system's text size, brightness and bars ([safe]: status bar, notch, gesture bar) set.
    void phone(
      WidgetTester tester, {
      double text = 1,
      bool dark = false,
      Size size = const Size(390, 844),
      EdgeInsets safe = EdgeInsets.zero,
    }) {
      final inset = FakeViewPadding(left: safe.left * 3, top: safe.top * 3, right: safe.right * 3, bottom: safe.bottom * 3);
      tester.view
        ..physicalSize = size * 3
        ..devicePixelRatio = 3
        ..padding = inset
        ..viewPadding = inset;
      tester.platformDispatcher
        ..textScaleFactorTestValue = text
        ..platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
    }

    for (final MapEntry(key: name, value: open) in screens.entries) {
      for (final dark in [false, true]) {
        testWidgets('$name, ${dark ? 'dark' : 'light'}: tap targets, labels and contrast', (tester) async {
          final semantics = tester.ensureSemantics();
          phone(tester, dark: dark);
          await open(tester);
          await tester.pumpAndSettle();
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          semantics.dispose();
        });
      }

      // The overflow stripes are FlutterErrors, which fail the test.
      testWidgets('$name: fits at 200 % text', (tester) async {
        phone(tester, text: 2);
        await open(tester);
        await tester.pumpAndSettle();
        expect(MediaQuery.textScalerOf(tester.element(find.byType(Scaffold).first)).scale(10), 20, reason: 'the phone is at 200 % text');
        final e = tester.takeException();
        expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
      });

      // Cutouts and bars: at rest, nothing is drawn under the status bar, a landscape notch or the gesture bar.
      // A landscape phone is too short for the content, which scrolls under the bars, so only its sides are checked.
      for (final (shape, size, safe) in [
        ('portrait', const Size(390, 844), const EdgeInsets.only(top: 47, bottom: 34)),
        ('landscape', const Size(844, 390), const EdgeInsets.fromLTRB(47, 0, 47, 21)),
      ]) {
        testWidgets('$name: text and icons stay inside the safe area in $shape', (tester) async {
          phone(tester, size: size, safe: safe);
          await open(tester);
          await tester.pumpAndSettle();
          final tall = size.height > size.width;
          final area = Rect.fromLTRB(safe.left, tall ? safe.top : -1e6, size.width - safe.right, tall ? size.height - safe.bottom : 1e6);
          for (final e in find.byType(RichText).evaluate()) {
            final r = tester.getRect(find.byWidget(e.widget));
            expect(area.inflate(0.5).expandToInclude(r), area.inflate(0.5), reason: '${(e.widget as RichText).text.toPlainText()} at $r');
          }
        });
      }
    }

    // What a screen reader user gets, beyond the guidelines above.

    /// The names of the custom actions on the node [finder] points into.
    List<String> actionsOn(WidgetTester tester, Finder finder) => [
      for (final id in tester.getSemantics(finder).getSemanticsData().customSemanticsActionIds ?? <int>[])
        CustomSemanticsAction.getAction(id)!.label!,
    ];

    /// Runs the custom action [label] on that node, as TalkBack's or VoiceOver's actions menu does.
    Future<void> act(WidgetTester tester, Finder finder, String label) async {
      final node = tester.getSemantics(finder);
      final id = node.getSemanticsData().customSemanticsActionIds!.firstWhere((id) => CustomSemanticsAction.getAction(id)!.label == label);
      tester.semantics.performAction(find.semantics.byPredicate((n) => n.id == node.id), SemanticsAction.customAction, args: id);
      await tester.pumpAndSettle();
    }

    testWidgets('Home: a document is one button, thumbnails are not announced, the dock buttons are enabled buttons', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      await screens['Home']!(tester);
      final tile = tester.getSemantics(find.text('Lease agreement'));
      // What follows the count is the date, which depends on today (a time, "Oct 27" or a full date): not pinned.
      expect(tile, isSemantics(isButton: true, hasTapAction: true));
      expect(tile.label, startsWith('Lease agreement\n3 pages'));
      expect(tile, isNot(isSemantics(isImage: true)));
      for (final label in ['Import', 'ID card']) {
        expect(tester.getSemantics(find.text(label)), isSemantics(isButton: true, hasEnabledState: true, isEnabled: true, label: label));
      }
      semantics.dispose();
    });

    testWidgets('Review Pages: each page is one named node with Move actions, and Move down reorders', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      final d = doc('Contract', ['a', 'b', 'c']);
      final library = Library(root, docs: [d]);
      await tester.pumpWidget(FolioApp(library: library));
      await tester.tap(find.text('Contract'));
      await tester.pumpAndSettle();

      final second = find.text('Page 2');
      expect(tester.getSemantics(second), isSemantics(isButton: true, hasTapAction: true, label: 'Page 2\nOriginal'));
      expect(actionsOn(tester, second), unorderedEquals(['Move to the start', 'Move up', 'Move down', 'Move to the end']));
      expect(
        actionsOn(tester, find.text('Page 3')),
        unorderedEquals(['Move to the start', 'Move up']),
        reason: 'the last page cannot move down',
      );
      expect(find.bySemanticsLabel('Drag to reorder'), findsNothing, reason: 'the handle is for fingers; the row has the actions');

      await act(tester, second, 'Move up');
      expect(library.byId(d.id)!.pages.map((p) => p.id), ['b', 'a', 'c']);
      await act(tester, find.text('Page 1'), 'Move to the end');
      expect(library.byId(d.id)!.pages.map((p) => p.id), ['a', 'c', 'b']);
      semantics.dispose();
    });

    testWidgets('Crop & Enhance: the page image is named, filters are buttons rather than images', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      await screens['Crop & Enhance']!(tester);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Page 1, Original'), findsOneWidget);
      final filter = tester.getSemantics(find.text('Enhance'));
      expect(filter, isSemantics(isButton: true, hasTapAction: true, label: 'Enhance'));
      expect(filter, isNot(isSemantics(isImage: true)));
      semantics.dispose();
    });

    // The controls used to sit under the page in landscape and leave it ~31 dp (5 dp at 200 % text): now they sit beside it.
    for (final text in [1.0, 2.0]) {
      testWidgets('Crop & Enhance, landscape phone at ${(text * 100).round()} % text: the page keeps its height, nothing overflows', (
        tester,
      ) async {
        phone(tester, size: const Size(844, 390), text: text, safe: const EdgeInsets.fromLTRB(47, 0, 47, 21));
        await screens['Crop & Enhance']!(tester);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(PageImage).first).height, greaterThanOrEqualTo(200));
        // The side panel spans the body, from under the app bar down to the gesture bar (21 dp inset).
        final panel = tester.getRect(find.ancestor(of: find.text('Filter'), matching: find.byType(SingleChildScrollView)).first);
        expect([panel.top, panel.bottom], [tester.getRect(find.byType(AppBar)).bottom, 390 - 21]);
        final e = tester.takeException();
        expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
      });
    }

    testWidgets('Preview: each sheet is named "Page n of m"', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      await screens['Preview']!(tester);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Page 1 of 3'), findsOneWidget);
      expect(find.bySemanticsLabel('1 of 3'), findsNothing, reason: 'the counter repeats it');
      semantics.dispose();
    });

    testWidgets('ID sheet: each step reads as one sentence', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      await screens['ID sheet']!(tester);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Step 1 of 2: Front side. Place the card on a dark, flat surface'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 2 of 2: Back side. Next'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Crop: each corner can be moved from the actions menu, and Done saves it', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      final d = doc('Notes', ['a', 'b']);
      File('${d.dir}/src/b.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 62, height: 88)));
      final library = Library(root, docs: [d]);
      await tester.pumpWidget(FolioApp(library: library));
      await tester.tap(find.text('Notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Page 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Crop'));
      final corner = find.bySemanticsLabel('Crop corner, top left');
      await until(tester, () => corner.evaluate().isNotEmpty); // the image size is read in an isolate

      expect(actionsOn(tester, corner), unorderedEquals(['Move left', 'Move right', 'Move up', 'Move down']));
      expect(tester.getSemantics(corner), isSemantics(value: '0 percent from the left, 0 percent from the top'));
      await act(tester, corner, 'Move right');
      await act(tester, corner, 'Move down');
      await act(tester, corner, 'Move left'); // 2 % again, and left at 0 % stays inside the image
      await act(tester, corner, 'Move left');
      await act(tester, corner, 'Move up');
      await act(tester, corner, 'Move up');
      expect(tester.getSemantics(corner), isSemantics(value: '0 percent from the left, 0 percent from the top'));
      await act(tester, corner, 'Move down');
      await act(tester, find.bySemanticsLabel('Crop corner, bottom right'), 'Move left');

      await tester.tap(find.text('Done'));
      await tester.pump(); // not settled: the edit starts a render, whose progress bar keeps animating
      final q = library.byId(d.id)!.pages[1].corners!;
      expect([q[0], q[1], q[4], q[5]], [0, closeTo(0.02, 1e-9), closeTo(0.98, 1e-9), 1]);
      semantics.dispose();
    });

    testWidgets('system bars are transparent and their icons contrast with the page, in light and dark', (tester) async {
      final styles = <Map<Object?, Object?>>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setSystemUIOverlayStyle') styles.add(call.arguments as Map<Object?, Object?>);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      // SystemChrome sends a style only when it differs from the last one set, in any earlier test too.
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle());
      for (final dark in [false, true]) {
        phone(tester, dark: dark);
        for (final screen in ['Home', 'Review Pages', 'Crop & Enhance']) {
          await screens[screen]!(tester);
          await tester.pumpAndSettle();
          final icons = dark ? 'Brightness.light' : 'Brightness.dark';
          expect(styles.last, containsPair('systemNavigationBarColor', 0), reason: screen);
          expect(styles.last, containsPair('systemNavigationBarContrastEnforced', null), reason: screen); // null: Android keeps its scrim
          expect(styles.last, containsPair('systemNavigationBarIconBrightness', icons), reason: screen);
          expect(styles.last, containsPair('statusBarIconBrightness', icons), reason: screen);
          await tester.pumpWidget(const SizedBox()); // a fresh app for the next screen
        }
      }
    });
  });
}

List<Document> _library() => [
  doc('Lease agreement', ['a', 'b', 'c']),
  doc('Grocery receipt with a rather long name to wrap', ['r'], ago: const Duration(days: 1)),
];
