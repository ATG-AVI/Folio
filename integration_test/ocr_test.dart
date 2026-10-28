import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';

import '../test/flate.dart';

/// The photo picker, faked: hands back whatever files the test queued.
class FakePicker extends ImagePickerPlatform {
  List<String> next = [];

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async => [
    for (final p in next) XFile(p),
  ];
}

const _copied = 'Text copied';
const _none = 'No text found on this page';
const _unavailable = 'Text recognition isn’t available right now. Try again in a minute.';

/// The real native recogniser (Vision, ML Kit) behind Copy text and the searchable PDF. Only the photo picker and the
/// system save dialog are fake. The PDF is copied to a known file and its path printed with an `OCRPDF:` prefix, so
/// the host can check it: `pdftotext <path> -` should show FOLIO SEARCH TEST 2026 (the Simulator's files are on the Mac).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final picker = FakePicker();
  ImagePickerPlatform.instance = picker;

  /// Pumps real time until [f] shows (imports, renders, recognition and the PDF build run off the UI thread).
  Future<void> waitFor(WidgetTester tester, Finder f, {int seconds = 60}) async {
    for (var i = 0; i < seconds * 20 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(f, findsWidgets);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 30));
  }

  /// Large, clean, black-on-white text. arial48 is the biggest bitmap font there is, so it is drawn on a half-size
  /// page and doubled: the letters come out about 100 px tall.
  String photo(Directory dir) {
    final small = img.Image(width: 600, height: 800)..clear(img.ColorRgb8(255, 255, 255));
    final black = img.ColorRgb8(0, 0, 0);
    img.drawString(small, 'FOLIO SEARCH', font: img.arial48, x: 40, y: 120, color: black);
    img.drawString(small, 'TEST 2026', font: img.arial48, x: 40, y: 220, color: black);
    final page = img.copyResize(small, width: 1200, height: 1600, interpolation: img.Interpolation.cubic);
    return (File('${dir.path}/ocr_page.jpg')..writeAsBytesSync(img.encodeJpg(page, quality: 95))).path;
  }

  testWidgets('Copy text and a searchable PDF read real text through the native recogniser', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('folio_ocr'); // kept: the host reads the PDF afterwards
    final library = await Library.open('${tmp.path}/library');
    await tester.pumpWidget(FolioApp(key: UniqueKey(), library: library));
    await tester.pumpAndSettle();
    picker.next = [photo(tmp)];
    await tap(tester, find.text('Import'));
    await waitFor(tester, find.text('Page 1 of 1'));
    await tap(tester, find.text('Done'));
    await waitFor(tester, find.text('Page 1'));
    await library.renderIdle();

    // (a) Android: ask native itself first. Native.recognizeText (so Copy text) turns a missing handler, `failed` and
    // `unavailable` into the same null, which would let a broken recogniser pass as "no model yet". Only `unavailable`
    // may, and the output below says so. (Never print e.message: it may carry text.)
    var unavailable = false;
    if (Platform.isAndroid) {
      final doc = library.query('', DocSort.recent).single;
      try {
        await const MethodChannel('folio/native').invokeListMethod<Object?>('recognizeText', {'path': doc.pathOf(doc.pages.single)});
      } on PlatformException catch (e) {
        expect(
          e.code,
          'unavailable',
          reason: 'native recognizeText failed with code ${e.code}; only `unavailable` (no model yet) may pass',
        );
        unavailable = true;
      } on MissingPluginException {
        fail('Android has no recognizeText handler on the folio/native channel.');
      }
    }

    // Copy text, through the real channel.
    await tap(tester, find.byTooltip('Page options'));
    await tap(tester, find.text('Copy text'));
    String? outcome;
    for (var i = 0; i < 1200 && outcome == null; i++) {
      for (final m in [_copied, _none, _unavailable]) {
        if (find.text(m).evaluate().isNotEmpty) outcome = m;
      }
      if (outcome == null) await tester.pump(const Duration(milliseconds: 50));
    }
    var reads = false; // did the recogniser give text?
    switch (outcome) {
      case _copied:
        final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        expect(copied, contains('FOLIO'), reason: 'the recogniser ran but did not read large, clean text (${copied?.length} characters)');
        reads = true;
      case _unavailable when Platform.isAndroid && unavailable:
        // An emulator cannot download ML Kit's model: nothing to assert about the text, only that nothing broke.
        debugPrint(
          'OCR: native recognizeText answered `unavailable` on this Android device (ML Kit model missing); skipping the text assertions',
        );
      case _unavailable when Platform.isAndroid:
        fail('Copy text found no recogniser, but native recognizeText answered the same page when asked directly.');
      case _unavailable:
        fail('Vision gave no text on iOS (unavailable or failed). Does Vision text recognition work on the Simulator? Try a device.');
      case _none:
        fail('The recogniser ran but found no text in a page of large, clean text.');
      default:
        fail('Copy text showed no result within 60 s.');
    }

    // Export with Searchable text. Only the save dialog is faked: recognizeText still reaches the native side.
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('folio/native');
    final native = MethodChannel(channel.name, channel.codec, messenger.delegate);
    final out = File('${tmp.path}/ocr_searchable.pdf');
    messenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'recognizeText') return native.invokeMethod<Object?>(c.method, c.arguments);
      if (c.method != 'saveAs') return null;
      File(c.arguments['path'] as String).copySync(out.path); // the sheet deletes its copy once the picker is done
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tap(tester, find.text('Export PDF'));
    await tap(tester, find.byType(SwitchListTile));
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    await tap(tester, find.text('Save to device'));
    await waitFor(tester, find.textContaining('Saved ·'));

    // What the export itself produced: its streams are deflated, so look inside them for invisible text (mode 3).
    final pdf = inflated(out.readAsBytesSync());
    final layer = pdf.contains(' 3 Tr');
    expect(pdf, startsWith('%PDF-'));
    if (reads) expect(layer, isTrue, reason: 'Copy text read text from this page, so the export should carry a text layer');
    // The sheet says "without searchable text" exactly when the PDF has no layer (it may have one even if the model
    // was missing for Copy text: it can arrive in between).
    expect(find.textContaining('without searchable text'), layer ? findsNothing : findsOneWidget);
    debugPrint('OCR: the export ${layer ? 'has' : 'has no'} text layer');
    debugPrint('OCRPDF:${out.path}');
  });
}
