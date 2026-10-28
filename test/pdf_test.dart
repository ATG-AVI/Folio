import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/document.dart';
import 'package:folio/export_sheet.dart' show sizeText;
import 'package:folio/ocr.dart';
import 'package:folio/pdf.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' show PdfDocument, PdfTtfFont;

import 'flate.dart';

/// One page as the PDF states it: /MediaBox, and for each drawn image its `cm` box, pixel size and embedded bytes.
typedef ParsedPage = ({List<double> box, List<({List<double> cm, int w, int h, Uint8List jpeg})> images});

/// Reads a PDF made by buildPdf or buildSearchablePdf (inflating its /FlateDecode streams), in page order.
List<ParsedPage> parsePdf(Uint8List pdf) {
  final s = latin1.decode(pdf); // one char per byte, so offsets and lengths stay byte-exact
  final objects = {for (final m in RegExp(r'(\d+) 0 obj\n(.*?)\nendobj', dotAll: true).allMatches(s)) int.parse(m[1]!): m[2]!};
  List<double> numbers(String t) => [for (final m in RegExp(r'-?[\d.]+').allMatches(t)) double.parse(m[0]!)];
  String stream(String obj) {
    final start = obj.indexOf('stream\n') + 7, length = int.parse(RegExp(r'/Length (\d+)').firstMatch(obj)![1]!);
    final raw = obj.substring(start, start + length);
    return obj.contains('/FlateDecode') ? inflate(raw) : raw; // the JPEGs are /DCTDecode and stay as they are
  }

  final kids = RegExp(r'/Kids\[([^\]]*)\]').firstMatch(s)![1]!;
  return [
    for (final k in RegExp(r'(\d+) 0 R').allMatches(kids))
      () {
        final page = objects[int.parse(k[1]!)]!;
        final xobjects = {
          for (final m in RegExp(r'/(\w+) (\d+) 0 R').allMatches(RegExp(r'/XObject<<(.*?)>>').firstMatch(page)![1]!))
            m[1]!: objects[int.parse(m[2]!)]!,
        };
        final content = stream(objects[int.parse(RegExp(r'/Contents (\d+) 0 R').firstMatch(page)![1]!)]!);
        return (
          box: numbers(RegExp(r'/MediaBox\[([^\]]*)\]').firstMatch(page)![1]!),
          // pdf emits exactly `q <w> 0 0 <h> <x> <y> cm /<name> Do Q ` for each image
          images: [
            for (final m in RegExp(r'q (\S+) 0 0 (\S+) (\S+) (\S+) cm /(\w+) Do Q').allMatches(content))
              (
                cm: numbers('${m[1]} ${m[2]} ${m[3]} ${m[4]}'),
                w: int.parse(RegExp(r'/Width (\d+)').firstMatch(xobjects[m[5]]!)![1]!),
                h: int.parse(RegExp(r'/Height (\d+)').firstMatch(xobjects[m[5]]!)![1]!),
                jpeg: latin1.encode(stream(xobjects[m[5]]!)),
              ),
          ],
        );
      }(),
  ];
}

/// One hidden line as the content stream states it: font size, horizontal scale in %, baseline origin, glyph codes.
typedef HiddenLine = ({double size, double tz, double x, double y, String codes});

/// The invisible text of a PDF made by buildSearchablePdf, in drawing order.
List<HiddenLine> hiddenLines(Uint8List pdf) => [
  for (final m in RegExp(r'BT /F\d+ (\S+) Tf (\S+) Tz 3 Tr (\S+) (\S+) Td \[<(\w*)>\]TJ ET').allMatches(inflated(pdf)))
    (size: double.parse(m[1]!), tz: double.parse(m[2]!), x: double.parse(m[3]!), y: double.parse(m[4]!), codes: m[5]!),
];

/// The text behind [l]'s glyph codes, read through the PDF's own /ToUnicode map, the way a viewer extracts it.
String textOf(Uint8List pdf, HiddenLine l) {
  final s = inflated(pdf);
  final map = {
    for (final m in RegExp(r'<([0-9A-F]{4})> <([0-9A-F]{4})>').allMatches(s.substring(s.indexOf('beginbfchar'))))
      m[1]!.toLowerCase(): int.parse(m[2]!, radix: 16),
  };
  return String.fromCharCodes([for (final m in RegExp('.{4}').allMatches(l.codes)) map[m[0]!]!]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the text layer's font comes from the asset bundle
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('folio_pdf'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A document whose pages are already rendered: noisy JPEGs (so their sizes are realistic) of the given
  /// pixel sizes, at `cache/<r>.jpg` where buildPdf looks for them.
  Document rendered(
    List<(int, int)> sizes, {
    PageSize size = PageSize.fit,
    DocKind kind = DocKind.document,
    String name = 'Lease agreement',
  }) {
    final rng = Random(7);
    var d = Document(
      id: 'doc',
      dir: tmp.path,
      name: name,
      kind: kind,
      pageSize: size,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      pages: [for (final (i, (w, h)) in sizes.indexed) DocPage(id: 'p$i', src: 'src/p$i.jpg', w: w, h: h)],
    );
    d = d.copyWith(pages: [for (final p in d.pages) p.copyWith(r: d.renderKey(p))]);
    Directory('${tmp.path}/cache').createSync();
    for (final p in d.pages) {
      final im = img.Image(width: p.w, height: p.h);
      for (final px in im) {
        final base = (px.x + px.y) * 255 ~/ (p.w + p.h);
        px
          ..r = (base + rng.nextInt(40)).clamp(0, 255)
          ..g = (255 - base + rng.nextInt(40)).clamp(0, 255)
          ..b = (base ~/ 2 + rng.nextInt(40)).clamp(0, 255);
      }
      File('${tmp.path}/${p.renderPath}').writeAsBytesSync(img.encodeJpg(im, quality: 75));
    }
    return d;
  }

  Uint8List jpegOf(Document d, int i) => File('${d.dir}/${d.pages[i].renderPath}').readAsBytesSync();

  const sizes = [(600, 800), (800, 600), (500, 700)];

  test('pages are in document order', () async {
    final d = rendered(sizes);
    expect([for (final p in parsePdf(await buildPdf(d))) (p.images.single.w, p.images.single.h)], sizes);
    final moved = d.movePage(0, 2);
    expect([for (final p in parsePdf(await buildPdf(moved))) (p.images.single.w, p.images.single.h)], [sizes[1], sizes[2], sizes[0]]);
  });

  test('page sizes in points: Fit, A4 (portrait and landscape) and Letter', () async {
    Future<List<(double, double)>> pages(Document d) async => [for (final p in parsePdf(await buildPdf(d))) (p.box[2], p.box[3])];
    void expectSizes(List<(double, double)> got, List<(double, double)> want) {
      expect(got, hasLength(want.length));
      for (final (i, (w, h)) in want.indexed) {
        expect(got[i].$1, closeTo(w, 0.01), reason: 'width of page $i');
        expect(got[i].$2, closeTo(h, 0.01), reason: 'height of page $i');
      }
    }

    expectSizes(await pages(rendered(sizes)), [(595.28, 595.28 * 800 / 600), (595.28, 595.28 * 600 / 800), (595.28, 595.28 * 700 / 500)]);
    expectSizes(await pages(rendered(sizes, size: PageSize.a4)), [(595.28, 841.89), (841.89, 595.28), (595.28, 841.89)]);
    expectSizes(await pages(rendered(sizes, size: PageSize.letter)), [(612, 792), (792, 612), (612, 792)]);
    expect(parsePdf(await buildPdf(rendered(sizes))).map((p) => p.box.take(2)).expand((e) => e), everyElement(0), reason: 'origin at 0, 0');
  });

  test('embeds the render files as they are: DCTDecode, DeviceRGB, byte for byte', () async {
    final d = rendered(sizes);
    final pdf = await buildPdf(d);
    final s = latin1.decode(pdf);
    expect(s, allOf(contains('/DCTDecode'), contains('/DeviceRGB'), contains('/Title(Lease agreement)')));
    expect(RegExp('/Subtype/Image').allMatches(s), hasLength(3));
    expect([for (final p in parsePdf(pdf)) p.images.single.jpeg], [for (var i = 0; i < 3; i++) jpegOf(d, i)]);
  });

  test('the title is a UTF-16BE string with its FE FF mark, so emoji and no-break spaces survive', () async {
    for (final name in ['Reçu 😀 (a\u00a0b)\\', 'Lease agreement ✓', '契約書']) {
      final s = latin1.decode(await buildPdf(rendered([(600, 800)], name: name)));
      // A literal string: pdf escapes parentheses and backslashes with a backslash.
      final raw = RegExp(r'/Title\(((?:\\.|[^\\)])*)\)', dotAll: true).firstMatch(s)![1]!;
      final bytes = latin1.encode(raw.replaceAllMapped(RegExp(r'\\(.)', dotAll: true), (m) => m[1]!));
      expect(bytes.take(2), [0xFE, 0xFF], reason: name);
      expect(String.fromCharCodes([for (var i = 2; i < bytes.length; i += 2) bytes[i] << 8 | bytes[i + 1]]), name);
    }
    final ascii = latin1.decode(await buildPdf(rendered([(600, 800)], name: 'Lease agreement')));
    expect(ascii, contains('/Title(Lease agreement)'), reason: 'plain names stay plain');
  });

  test('startxref and every xref entry point at the byte where their object starts', () async {
    final s = latin1.decode(await buildPdf(rendered(sizes))); // one char per byte, so offsets are byte offsets
    final at = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(s)![1]!);
    final head = s.substring(at, s.indexOf('stream\n', at)); // the xref is itself an object, with a binary table
    expect(head, contains('/Type/XRef'));
    final w = [for (var i = 1; i <= 3; i++) int.parse(RegExp(r'/W\[(\d+) (\d+) (\d+)\]').firstMatch(head)![i]!)];
    final size = int.parse(RegExp(r'/Size (\d+)').firstMatch(head)![1]!),
        length = int.parse(RegExp(r'/Length (\d+)').firstMatch(head)![1]!);
    final row = w.reduce((a, b) => a + b);
    expect(length, size * row, reason: 'one row per object, no /Index');
    final table = latin1.encode(s.substring(at + head.length + 7, at + head.length + 7 + length));
    expect(size, greaterThan(sizes.length * 3), reason: 'pages, contents and images');
    for (var i = 1; i < size; i++) {
      var offset = 0;
      for (var k = 0; k < w[1]; k++) {
        offset = offset << 8 | table[i * row + w[0] + k];
      }
      expect(s.substring(offset), startsWith('$i 0 obj'), reason: 'object $i');
    }
  });

  test('file size is the JPEGs plus under 5 % overhead', () async {
    final d = rendered(sizes);
    final jpegs = [for (var i = 0; i < 3; i++) jpegOf(d, i).length].reduce((a, b) => a + b);
    expect(jpegs, greaterThan(250 * 1024), reason: 'realistic page sizes, or the ratio proves nothing');
    final pdf = (await buildPdf(d)).length;
    expect(pdf, greaterThan(jpegs));
    expect(pdf, lessThan(jpegs * 1.05));
  });

  test('a duplicated page shares one embedded image', () async {
    final pdf = await buildPdf(rendered([(600, 800)]).duplicatePage(0));
    expect(parsePdf(pdf), hasLength(2));
    expect(RegExp('/Subtype/Image').allMatches(latin1.decode(pdf)), hasLength(1));
  });

  test('preview rects are the PDF rects (PDF y runs up from the bottom)', () async {
    final docs = [
      rendered(sizes),
      rendered(sizes, size: PageSize.a4),
      rendered(sizes, size: PageSize.letter),
      rendered([(476, 300), (300, 476)], kind: DocKind.idCard, size: PageSize.a4), // both sides on one page
    ];
    for (final d in docs) {
      final planned = layout(d), written = parsePdf(await buildPdf(d));
      expect(written, hasLength(planned.length));
      for (final (i, page) in planned.indexed) {
        expect(written[i].box[2], closeTo(page.size.width, 0.01));
        expect(written[i].box[3], closeTo(page.size.height, 0.01));
        expect(written[i].images, hasLength(page.images.length));
        for (final (j, (_, rect)) in page.images.indexed) {
          final [w, h, x, y] = written[i].images[j].cm;
          expect(
            [w, h, x, y],
            [
              closeTo(rect.width, 0.01),
              closeTo(rect.height, 0.01),
              closeTo(rect.left, 0.01),
              closeTo(page.size.height - rect.bottom, 0.01),
            ],
          );
        }
      }
    }
  });

  test('a page without an up-to-date render is an error, not a blank page', () async {
    final d = rendered(sizes);
    await expectLater(
      buildPdf(d.updatePage(1, d.pages[1].copyWith(filter: PageFilter.bw))),
      throwsStateError,
      reason: 'edited since its render',
    );
    final fresh = Document(
      id: 'x',
      dir: tmp.path,
      name: 'n',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      pages: [const DocPage(id: 'a', src: 'src/a.jpg', w: 10, h: 10)],
    );
    await expectLater(buildPdf(fresh), throwsStateError, reason: 'never rendered');
  });

  group('text layer (searchable PDF)', () {
    // Roboto's hhea ascent and descent in ems (1900 and -500 of 2048): what the font file says, pinned so a font swap shows.
    const asc = 1900 / 2048, desc = -500 / 2048;
    final roboto = PdfTtfFont(PdfDocument(), ByteData.sublistView(File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync()));
    const box = Rect.fromLTRB(0.1, 0.2, 0.6, 0.25);

    Map<String, List<OcrLine>> textFor(Document d, List<OcrLine> lines, [int page = 0]) => {d.pathOf(d.pages[page]): lines};

    test('the font file is the Roboto the geometry assumes', () {
      expect([roboto.ascent, roboto.descent, roboto.unitsPerEm], [asc, desc, 2048]);
    });

    test('a line’s box lands on its image: x, em box (selection), size and width follow the rules in Fit, A4 and Letter', () async {
      for (final size in PageSize.values) {
        final d = rendered([(600, 800)], size: size);
        final page = layout(d).single, rect = page.images.single.$2;
        final built = await buildSearchablePdf(d, textFor(d, [const OcrLine('Hello World', box)]));
        expect(built.textLayer, isTrue);
        final line = hiddenLines(built.bytes).single;

        final w = box.width * rect.width, h = box.height * rect.height;
        expect(line.size, closeTo(h / (asc - desc), 0.01), reason: '$size: ascent + descent as tall as the box');
        expect(line.x, closeTo(rect.left + box.left * rect.width, 0.5), reason: '$size: x');
        // PDF's origin is bottom-left: the em box (descent below the baseline, ascent above) is the box, flipped.
        expect(line.y + desc * line.size, closeTo(page.size.height - (rect.top + box.bottom * rect.height), 0.5), reason: '$size: bottom');
        expect(line.y + asc * line.size, closeTo(page.size.height - (rect.top + box.top * rect.height), 0.5), reason: '$size: top');
        // Width of the string at that size and scale == the box's width.
        expect(roboto.stringMetrics('Hello World').advanceWidth * line.size * line.tz / 100, closeTo(w, 0.5), reason: '$size: width');
        expect(textOf(built.bytes, line), 'Hello World');
      }
    });

    test('text is drawn before (under) the image, which is still embedded byte for byte', () async {
      final d = rendered([(600, 800), (800, 600)]);
      final bytes = (await buildSearchablePdf(d, textFor(d, [const OcrLine('Page one', box)]))).bytes;
      final s = inflated(bytes);
      expect(s.indexOf(' 3 Tr'), lessThan(s.indexOf(' Do Q')), reason: 'invisible text first, then the picture over it');
      expect(hiddenLines(bytes), hasLength(1), reason: 'only page one had lines');
      expect([for (final p in parsePdf(bytes)) p.images.single.jpeg], [for (var i = 0; i < 2; i++) jpegOf(d, i)]);
      expect(s, allOf(contains('/Title(Lease agreement)'), contains('/Identity-H')));
    });

    test('both sides of an ID card keep their own lines, each inside its own image', () async {
      final d = rendered([(476, 300), (300, 476)], kind: DocKind.idCard, size: PageSize.a4);
      final page = layout(d).single;
      final built = await buildSearchablePdf(d, {
        ...textFor(d, [const OcrLine('FRONT SIDE', box)]),
        ...textFor(d, [const OcrLine('BACK SIDE', box)], 1),
      });
      final lines = hiddenLines(built.bytes);
      expect([for (final l in lines) textOf(built.bytes, l)], ['FRONT SIDE', 'BACK SIDE']);
      for (final (i, l) in lines.indexed) {
        final rect = page.images[i].$2;
        expect(l.x, closeTo(rect.left + box.left * rect.width, 0.5), reason: 'side $i x');
        expect(l.y + asc * l.size, closeTo(page.size.height - (rect.top + box.top * rect.height), 0.5), reason: 'side $i top');
      }
    });

    test('pages that share a render share its lines', () async {
      final d = rendered([(600, 800)]).duplicatePage(0);
      final built = await buildSearchablePdf(d, textFor(d, [const OcrLine('Same page', box)]));
      expect([for (final l in hiddenLines(built.bytes)) textOf(built.bytes, l)], ['Same page', 'Same page']);
    });

    test('characters the font lacks, control characters and unusable lines never fail the export', () async {
      final d = rendered([(600, 800)]);
      final built = await buildSearchablePdf(
        d,
        textFor(d, [
          const OcrLine('AB😀C\u0000D\nE ✓ café', box),
          const OcrLine('😀😀', Rect.fromLTRB(0.1, 0.3, 0.5, 0.35)), // nothing left after dropping
          const OcrLine('', Rect.fromLTRB(0.1, 0.4, 0.5, 0.45)),
          const OcrLine('No width', Rect.fromLTRB(0.1, 0.5, 0.1, 0.55)),
          const OcrLine('No height', Rect.fromLTRB(0.1, 0.6, 0.5, 0.6)),
        ]),
      );
      expect(built.textLayer, isTrue);
      final lines = hiddenLines(built.bytes);
      expect([for (final l in lines) textOf(built.bytes, l)], ['ABC D E café']);
      final w = box.width * layout(d).single.images.single.$2.width;
      expect(
        roboto.stringMetrics('ABC D E café').advanceWidth * lines.single.size * lines.single.tz / 100,
        closeTo(w, 0.5),
        reason: 'the width is the cleaned string’s',
      );
      expect(parsePdf(built.bytes).single.images, hasLength(1));
    });

    test('Ohm and Increment share a glyph with Omega and Delta, which the subsetter rejects: they are folded, the layer stays', () async {
      final d = rendered([(600, 800)]);
      // U+2126 and U+03A9 together, U+2206 and U+0394 together: unfolded, Roboto's one glyph for each pair throws.
      final built = await buildSearchablePdf(d, textFor(d, [const OcrLine('R = 5 \u2126 \u03A9, \u2206T \u0394', box)]));
      expect(built.textLayer, isTrue);
      expect(textOf(built.bytes, hiddenLines(built.bytes).single), 'R = 5 \u03A9 \u03A9, \u0394T \u0394');
    });

    test('a layer where every line was dropped is no layer: the plain PDF is built and textLayer says false', () async {
      final d = rendered(sizes);
      for (final (why, lines) in <(String, List<OcrLine>)>[
        ('only characters the font lacks', [const OcrLine('😀😀', box)]),
        ('only empty boxes', [const OcrLine('Hello', Rect.fromLTRB(0.1, 0.2, 0.1, 0.25))]),
      ]) {
        final built = await buildSearchablePdf(d, textFor(d, lines));
        expect(built.textLayer, isFalse, reason: why);
        expect(inflated(built.bytes), isNot(contains(' Tr')), reason: why);
        expect(latin1.decode(built.bytes), isNot(contains('/FlateDecode')), reason: '$why: the plain PDF, not a layerless text build');
        expect(built.bytes.length, (await buildPdf(d)).length, reason: why); // not byte-equal: each PDF gets its own random /ID
      }
    });

    test('only a text layer is deflated: JPEGs stay /DCTDecode byte for byte, and a PDF without one has no Flate stream', () async {
      final d = rendered(sizes);
      final plain = latin1.decode(await buildPdf(d));
      expect(plain, isNot(contains('/FlateDecode')));
      final built = await buildSearchablePdf(d, textFor(d, [const OcrLine('Hello', box)]));
      final s = latin1.decode(built.bytes);
      expect(RegExp('/FlateDecode').allMatches(s), isNotEmpty, reason: 'the font, ToUnicode and content streams');
      expect(RegExp('/DCTDecode').allMatches(s), hasLength(3));
      expect([for (final p in parsePdf(built.bytes)) p.images.single.jpeg], [for (var i = 0; i < 3; i++) jpegOf(d, i)]);
      expect(textOf(built.bytes, hiddenLines(built.bytes).single), 'Hello');
    });

    test('a dense page’s text layer adds under 16 KB (about 27 KB when the streams were written raw)', () async {
      final d = rendered([(600, 800)]);
      final rng = Random(3);
      const words = [
        'invoice',
        'Total',
        'amount',
        'due',
        '2026-10-28',
        'Folio',
        'Scanner',
        'quick',
        'brown',
        'fox',
        'jumps',
        'over',
        'VAT',
      ];
      final lines = [
        for (var i = 0; i < 60; i++)
          OcrLine(
            [for (var j = 0; j < 9; j++) words[rng.nextInt(words.length)]].join(' '),
            Rect.fromLTWH(0.08, 0.03 + i * 0.015, 0.84, 0.012),
          ),
      ];
      final plain = (await buildPdf(d)).length;
      final built = await buildSearchablePdf(d, textFor(d, lines));
      expect(hiddenLines(built.bytes), hasLength(60));
      expect(built.bytes.length - plain, inInclusiveRange(1024, 16 * 1024));
    });

    test('the font is subset: a full page of text adds kilobytes, not the 170 KB font', () async {
      final d = rendered([(600, 800)]);
      final plain = (await buildPdf(d)).length;
      final lines = [
        for (var i = 0; i < 40; i++)
          OcrLine('The quick brown fox jumps over the lazy dog $i', Rect.fromLTWH(0.1, 0.02 + i * 0.02, 0.8, 0.015)),
      ];
      final searchable = (await buildSearchablePdf(d, textFor(d, lines))).bytes.length;
      expect(searchable - plain, inInclusiveRange(1024, 40 * 1024));
    });

    test('if the text layer can’t be built, the PDF is built again without it, whole, and says so', () async {
      final d = rendered(sizes);
      for (final (why, load) in <(String, Future<Uint8List> Function())>[
        ('the font won’t load', () async => throw StateError('no such asset')),
        ('the font file is broken (fails inside the isolate)', () async => Uint8List(64)),
      ]) {
        final built = await buildSearchablePdf(d, textFor(d, [const OcrLine('Hello', box)]), loadFont: load);
        expect(built.textLayer, isFalse, reason: why);
        expect(inflated(built.bytes), isNot(contains(' Tr')), reason: why);
        expect([for (final p in parsePdf(built.bytes)) p.images.single.jpeg], [for (var i = 0; i < 3; i++) jpegOf(d, i)], reason: why);
      }
    });

    test('no lines anywhere: no font is loaded and there is no text layer', () async {
      final d = rendered(sizes);
      var loads = 0;
      for (final text in [<String, List<OcrLine>>{}, textFor(d, []), textFor(d, [], 2)]) {
        final built = await buildSearchablePdf(
          d,
          text,
          loadFont: () async {
            loads++;
            return Uint8List(0);
          },
        );
        expect(built.textLayer, isFalse);
        expect(parsePdf(built.bytes), hasLength(3));
      }
      expect(loads, 0);
    });

    test('a page without an up-to-date render is still an error, with or without text', () async {
      final d = rendered(sizes);
      final stale = d.updatePage(1, d.pages[1].copyWith(filter: PageFilter.bw));
      await expectLater(buildSearchablePdf(stale, textFor(d, [const OcrLine('Hello', box)])), throwsStateError);
    });

    test('poppler, when installed, extracts the hidden text where the box is', () async {
      final d = rendered([(600, 800)], size: PageSize.a4);
      final bytes = (await buildSearchablePdf(d, textFor(d, [const OcrLine('FOLIO SEARCH TEST 2026', box)]))).bytes;
      final pdf = File('${tmp.path}/t.pdf')..writeAsBytesSync(bytes);
      final text = await Process.run('pdftotext', ['-bbox', pdf.path, '-']).catchError((Object _) => ProcessResult(0, 127, '', ''));
      if (text.exitCode != 0) return; // optional host check
      expect(text.stdout, allOf(contains('>FOLIO<'), contains('>SEARCH<'), contains('>2026<')));
      final rect = layout(d).single.images.single.$2;
      final first = RegExp(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="[\d.]+" yMax="([\d.]+)">FOLIO<').firstMatch(text.stdout as String)!;
      expect(double.parse(first[1]!), closeTo(rect.left + box.left * rect.width, 0.5));
      expect(double.parse(first[2]!), closeTo(rect.top + box.top * rect.height, 1)); // poppler's y runs down from the top
      expect(double.parse(first[3]!), closeTo(rect.top + box.bottom * rect.height, 1));
    });
  });

  group('fileNameFor', () {
    test('keeps ordinary names, including inner dots', () {
      expect(fileNameFor('Scan 2026-10-27 18.40'), 'Scan 2026-10-27 18.40');
      expect(fileNameFor('Électricité – octobre'), 'Électricité – octobre');
    });

    test('replaces what file systems reject', () {
      expect(fileNameFor(r'a/b\c:d*e?f"g<h>i|j'), 'a-b-c-d-e-f-g-h-i-j');
      expect(fileNameFor('a\u0000b\u001fc\u007fd\te\nf'), 'a-b-c-d-e-f');
    });

    test('collapses whitespace and trims spaces and dots at both ends', () {
      expect(fileNameFor('  a   b    c  '), 'a b c');
      expect(fileNameFor('..hidden.name..'), 'hidden.name');
      expect(fileNameFor(' . Lease . '), 'Lease');
    });

    test('falls back to Scan when nothing is left', () {
      for (final s in ['', '   ', '...', ' . . ']) {
        expect(fileNameFor(s), 'Scan', reason: '"$s"');
      }
      expect(fileNameFor('///'), '---', reason: 'replaced characters still count as a name');
    });

    test('keeps ".pdf" under Android’s 255-byte limit, cutting whole characters', () {
      for (final c in ['契', 'क', '😀', 'é']) {
        final n = fileNameFor(c * 100);
        expect(utf8.encode('$n.pdf').length, lessThanOrEqualTo(244), reason: c);
        expect(n, isNotEmpty);
        expect(n.replaceAll(c, ''), isEmpty, reason: 'only whole $c characters');
      }
      expect(fileNameFor('契' * 100), '契' * 80);
      expect(fileNameFor('क' * 100), 'क' * 80);
      expect(fileNameFor('😀' * 100), '😀' * 50, reason: 'the 100-unit cap still binds first');
      expect(fileNameFor('${'a' * 10}${'契' * 90}'), '${'a' * 10}${'契' * 76}', reason: '238 bytes; one more character would be 241');
      expect(fileNameFor('${'契' * 79} 契'), '契' * 79, reason: 'the cut leaves no trailing space');
    });

    test('caps at 100 characters without splitting a surrogate pair or ending on a space', () {
      expect(fileNameFor('a' * 150), 'a' * 100);
      expect(fileNameFor('${'a' * 98}😀'), '${'a' * 98}😀', reason: 'fits exactly');
      expect(fileNameFor('${'a' * 99}😀b'), 'a' * 99, reason: 'the pair would straddle the cap');
      expect(fileNameFor('${'a' * 99} bbb'), 'a' * 99);
    });
  });

  test('sizeText: KB under 1 MB (at least 1), else MB with one decimal', () {
    expect(
      [
        for (final b in [0, 1, 700, 1536, 340 * 1024, 1024 * 1024 - 1]) sizeText(b),
      ],
      ['1 KB', '1 KB', '1 KB', '2 KB', '340 KB', '1.0 MB'],
    );
    expect(
      [
        for (final b in [1024 * 1024, 1288490, 5 * 1024 * 1024]) sizeText(b),
      ],
      ['1.0 MB', '1.2 MB', '5.0 MB'],
    );
  });
}
