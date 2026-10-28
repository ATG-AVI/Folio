import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart';
import 'package:folio/pdf.dart' show fileNameFor;
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/src/interface.dart';

/// The photo picker, faked: hands back whatever files the test queued.
class FakePicker extends ImagePickerPlatform {
  List<String> next = [];

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async => [
    for (final p in next) XFile(p),
  ];
}

/// The share sheet, faked: remembers what it was given. Nothing else of printing is reached.
class FakeShare extends PrintingPlatform {
  Uint8List? bytes;
  String? name;

  @override
  Future<bool> sharePdf(Uint8List bytes, String filename, Rect bounds, String? subject, String? body, List<String>? emails) async {
    this.bytes = bytes;
    name = filename;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Export on a device: real library, renders, isolate and temp files. Only the picker, the system save
/// dialog and the share sheet are fake, since they are system UI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final picker = FakePicker();
  ImagePickerPlatform.instance = picker;
  late Library library;

  /// Pumps real time until [f] shows (imports, renders and the PDF build run on real isolates).
  Future<void> waitFor(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 300 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(f, findsWidgets);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  /// Imports two photos of different shapes, goes to Review Pages, and opens the export sheet.
  Future<void> openExport(WidgetTester tester) async {
    final tmp = Directory.systemTemp.createTempSync('folio_export');
    library = await Library.open('${tmp.path}/library');
    await tester.pumpWidget(FolioApp(key: UniqueKey(), library: library));
    await tester.pumpAndSettle();
    picker.next = [
      for (final (i, (w, h)) in [(900, 1200), (1200, 800)].indexed)
        (File(
          '${tmp.path}/pick$i.jpg',
        )..writeAsBytesSync(img.encodeJpg(img.Image(width: w, height: h)..clear(img.ColorRgb8(240, 238, 230)), quality: 90))).path,
    ];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 2'));
    await tap(tester, find.text('Done'));
    await waitFor(tester, find.text('Page 2'));
    await library.renderIdle();
    await tap(tester, find.text('Export PDF'));
  }

  String pdfName() => '${fileNameFor(library.query('', DocSort.recent).single.name)}.pdf';

  /// The structure of a two-page, two-image PDF, from its text (the pdf package writes no spaces after `/Type`).
  void expectTwoPagePdf(Uint8List bytes) {
    final text = latin1.decode(bytes);
    expect(text, startsWith('%PDF-'));
    expect(RegExp(r'/Type\s*/Page(?![a-z])').allMatches(text), hasLength(2));
    expect(RegExp(r'/Subtype\s*/Image').allMatches(text), hasLength(2));
    expect(text, contains('/DCTDecode'));
  }

  testWidgets('Save to device gives the picker a valid two-page PDF named after the document, then removes its copy', (tester) async {
    await openExport(tester);
    late String path, name;
    late Uint8List bytes;
    const channel = MethodChannel('folio/native');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method != 'saveAs') return null;
      path = c.arguments['path'] as String;
      name = c.arguments['name'] as String;
      bytes = File(path).readAsBytesSync(); // the sheet deletes the file once the picker is done
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await tap(tester, find.text('Save to device'));
    await waitFor(tester, find.textContaining('Saved ·'));
    expectTwoPagePdf(bytes);
    expect(name, pdfName());
    expect(path, '${(await getTemporaryDirectory()).path}/folio/$name');
    expect(File(path).existsSync(), isFalse);
  });

  testWidgets('Share hands the same kind of PDF to the share sheet', (tester) async {
    final share = FakeShare(), real = PrintingPlatform.instance;
    PrintingPlatform.instance = share;
    addTearDown(() => PrintingPlatform.instance = real);
    await openExport(tester);

    await tap(tester, find.text('Share'));
    for (var i = 0; i < 100 && share.bytes == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expectTwoPagePdf(share.bytes!);
    expect(share.name, pdfName());
  });
}
