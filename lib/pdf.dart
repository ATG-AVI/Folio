import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';

import 'document.dart';
import 'ocr.dart';

/// PDF points per millimetre.
const mm = 72 / 25.4;
const _a4 = Size(595.28, 841.89), _letter = Size(612, 792), _margin = 10 * mm;

/// One PDF page: its size in points and where each image goes (top-left origin).
typedef PageLayout = ({Size size, List<(DocPage, Rect)> images});

/// Single source of truth for page geometry, shared by the preview and [buildPdf].
List<PageLayout> layout(Document d) {
  final paper = d.pageSize == PageSize.letter ? _letter : _a4;
  if (d.kind == DocKind.idCard) return [_idCard(d.pages.take(2).toList(), paper)];
  return [for (final p in d.pages) _single(p, d.pageSize, paper)];
}

PageLayout _single(DocPage p, PageSize size, Size paper) {
  final px = p.size;
  if (size == PageSize.fit) {
    final page = Size(_a4.width, _a4.width * px.height / px.width);
    return (size: page, images: [(p, Offset.zero & page)]);
  }
  if (px.width > px.height) paper = paper.flipped;
  final k = min((paper.width - 2 * _margin) / px.width, (paper.height - 2 * _margin) / px.height);
  return (size: paper, images: [(p, _centred(paper, px * k, (paper.height - px.height * k) / 2))]);
}

/// Both sides on one page. ID-1-like sides print at real size (85.6 mm long edge); other cards share
/// one scale so the larger long edge is 85.6 mm. Everything shrinks together if it would not fit.
PageLayout _idCard(List<DocPage> sides, Size paper) {
  const id1 = 85.6 * mm, gap = 12 * mm;
  final px = sides.map((p) => p.size).toList();
  final longest = px.map((s) => s.longestSide).reduce(max);
  bool id1Like(Size s) => ((s.longestSide / s.shortestSide) / 1.586 - 1).abs() <= 0.06;
  var sizes = [for (final s in px) s * (id1 / (id1Like(s) ? s.longestSide : longest))];
  final stackH = sizes.fold(0.0, (a, s) => a + s.height) + gap * (sizes.length - 1);
  final widest = sizes.map((s) => s.width).reduce(max);
  final k = min(1.0, min((paper.height - 2 * _margin) / stackH, (paper.width - 2 * _margin) / widest));
  sizes = [for (final s in sizes) s * k];
  var y = (paper.height - stackH * k) / 2;
  final images = <(DocPage, Rect)>[];
  for (var i = 0; i < sides.length; i++) {
    images.add((sides[i], _centred(paper, sizes[i], y)));
    y += sizes[i].height + gap * k;
  }
  return (size: paper, images: images);
}

Rect _centred(Size paper, Size s, double top) => Offset((paper.width - s.width) / 2, top) & s;

/// The PDF for [d]: each page is its cached render, embedded as the JPEG it already is (never decoded).
/// Call after `Library.renderIdle()`; a page without an up-to-date render is a bug, so this throws.
Future<Uint8List> buildPdf(Document d) => _build(d);

/// [buildPdf] with an invisible text layer under each page image (PRD O3). [text] is keyed by render file path
/// (`Document.pathOf`), so pages sharing a render share their lines. If anything throws while building with the
/// layer, the PDF is built again without it (OCR never blocks an export): [textLayer] says which one you got, and
/// is false too when [text] has no lines at all. [loadFont] is the font file's bytes, injectable for tests.
Future<({Uint8List bytes, bool textLayer})> buildSearchablePdf(
  Document d,
  Map<String, List<OcrLine>> text, {
  Future<Uint8List> Function() loadFont = _roboto,
}) async {
  if (text.values.any((l) => l.isNotEmpty)) {
    try {
      return (bytes: await _build(d, text: text, font: await loadFont()), textLayer: true);
    } catch (_) {
      // Fall through: a PDF without text beats no PDF.
    }
  }
  return (bytes: await _build(d), textLayer: false);
}

/// Roboto Regular (Apache-2.0, assets/fonts): Latin, Greek and Cyrillic, which is what O4 asks for. Only the glyphs
/// a document uses are embedded.
Future<Uint8List> _roboto() async {
  final b = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
  return b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
}

Future<Uint8List> _build(Document d, {Map<String, List<OcrLine>>? text, Uint8List? font}) async {
  // Plain numbers and paths (and the recognised lines): the isolate never receives the Document.
  final pages = [
    for (final l in layout(d))
      (l.size.width, l.size.height, [for (final (p, r) in l.images) (_renderFile(d, p), r.left, r.top, r.width, r.height)]),
  ];
  final title = _pdfTitle(d.name);
  return Isolate.run(() async {
    // Deflate only with a text layer: a dense page's streams are ~27 KB raw (the text ~17, the ASCII85'd font ~9) and
    // ~7 KB deflated, while without one the content streams are a few bytes. The JPEGs are never touched: /DCTDecode
    // passes through.
    final pdf = PdfDocument(compress: font != null);
    PdfInfo(pdf, title: title);
    final ttf = font == null ? null : PdfTtfFont(pdf, ByteData.sublistView(font));
    final jpegs = <String, PdfImage>{}; // duplicated pages share one render, so one embedded image
    var drawn = 0; // text lines that made it onto a page
    for (final (w, h, images) in pages) {
      final g = PdfPage(pdf, pageFormat: PdfPageFormat(w, h)).getGraphics();
      for (final (path, left, top, width, height) in images) {
        if (ttf != null) drawn += _hiddenText(g, ttf, text?[path] ?? const [], h, Rect.fromLTWH(left, top, width, height));
        // Limit: every JPEG stays in memory until write(), so the peak is about 3x the PDF (370 MB for 100
        // High pages). PdfImage.jpegStream would bring it to ~2x if M7's 100-page export test needs it.
        final jpeg = jpegs.putIfAbsent(path, () => PdfImage.jpeg(pdf, image: File(path).readAsBytesSync()));
        g.drawImage(jpeg, left, h - top - height, width, height); // PDF's origin is bottom-left
      }
    }
    // Every line dropped: buildSearchablePdf rebuilds without the layer and says so, rather than claim text that isn't there.
    if (ttf != null && drawn == 0) throw StateError('no text left to embed');
    // write(), not save(): save() would hand the whole document to yet another isolate.
    final out = _ChunkedStream();
    await pdf.write(out);
    return out.output();
  });
}

/// Invisible text for [lines] over the image at [at] (top-left origin) on a page [pageH] points tall. Each line's box
/// becomes its em box: the size makes ascent + descent as tall as the box, so selections cover the line, and the
/// horizontal scale makes the string as wide as the box. Drawn before the image, which is why it is "under" it.
/// Returns how many lines it drew.
/// Limit: horizontal lines only; rotated text ends up as a thin, wide box. Needs the angle from the recogniser.
int _hiddenText(PdfGraphics g, PdfTtfFont font, List<OcrLine> lines, double pageH, Rect at) {
  var drawn = 0;
  for (final line in lines) {
    // Control characters become spaces and glyphs the font lacks are dropped: one odd character never costs the page.
    // Ohm and Increment are folded into Omega and Delta first: Roboto gives each pair one glyph, and the subsetter
    // throws on two characters sharing one, which would cost the whole document its text layer.
    final s = String.fromCharCodes(
      line.text
          .replaceAll(RegExp(r'[\s\p{Cc}]+', unicode: true), ' ')
          .replaceAll('\u2126', '\u03A9')
          .replaceAll('\u2206', '\u0394')
          .runes
          .where(font.isRuneSupported),
    ).replaceAll(RegExp(' {2,}'), ' ').trim();
    final box = line.box, em = s.isEmpty ? 0 : font.stringMetrics(s).advanceWidth; // in ems
    final w = box.width * at.width, h = box.height * at.height;
    if (em <= 0 || w <= 0 || h <= 0) continue;
    final size = h / (font.ascent - font.descent); // descent is negative
    final bottom = pageH - (at.top + box.bottom * at.height); // PDF's origin is bottom-left
    g.drawString(
      font,
      size,
      s,
      at.left + box.left * at.width,
      bottom - font.descent * size, // the baseline sits |descent| above the box's bottom
      scale: w / (em * size),
      mode: PdfTextRenderingMode.invisible,
    );
    drawn++;
  }
  return drawn;
}

/// The pdf package's PdfStream grows by a fixed 64 KB, so writing N JPEGs copies everything so far ~N times
/// (100 High pages: ~1 s and a big memory peak, instead of ~0.1 s). This keeps each chunk it is given and
/// joins them once, at the end.
/// Not for verbose PDFs: those patch earlier bytes with setBytes.
class _ChunkedStream extends PdfStream {
  final _chunks = BytesBuilder(copy: false); // fine: the writer never changes a list after handing it over

  @override
  void putByte(int s) => _chunks.addByte(s);

  @override
  void putBytes(List<int> s) => _chunks.add(s);

  @override
  int get offset => _chunks.length;

  /// Joins the chunks and empties the stream, so call it once, last.
  @override
  Uint8List output() => _chunks.takeBytes();
}

/// PdfInfo turns a title into Latin-1 when it can, which viewers read as PDFDocEncoding (a no-break space
/// shows as €), and otherwise into UTF-16BE that drops every character outside the BMP (emoji become ��).
/// Latin-1 characters spelling the UTF-16BE bytes with their FE FF marker come out as exactly those bytes.
String _pdfTitle(String s) => s.codeUnits.every((u) => u < 0x80)
    ? s
    : String.fromCharCodes([
        0xFE,
        0xFF,
        for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
      ]);

String _renderFile(Document d, DocPage p) =>
    d.isRendered(p) ? '${d.dir}/${p.renderPath}' : throw StateError('Page ${p.id} has no up-to-date render');

/// A file name for [name] (PRD X4), without ".pdf": no characters that Android or iOS file systems
/// reject, no leading or trailing dots, at most 100 characters and 240 UTF-8 bytes (Android's limit is
/// 255 bytes, and ".pdf" and a picker's " (1)" need room: 100 CJK characters alone are 300), "Scan" if
/// nothing is left.
String fileNameFor(String name) {
  final s = name
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f\x7f]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  var units = 0, bytes = 0;
  for (final r in s.runes) {
    // Whole characters only, so a surrogate pair is never cut in half.
    final u = r > 0xFFFF ? 2 : 1, b = r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
    if (units + u > 100 || bytes + b > 240) break;
    units += u;
    bytes += b;
  }
  final cut = s.substring(0, units).replaceAll(RegExp(r'[ .]+$'), '');
  return cut.isEmpty ? 'Scan' : cut;
}
