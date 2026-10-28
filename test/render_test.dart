import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/document.dart';
import 'package:folio/library.dart';
import 'package:folio/render.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('folio_render'));
  // Best effort: a background render may still be finishing in this folder.
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS clears its temp folder; a stray file here doesn't matter.
    }
  });

  String write(String name, List<int> bytes) => (File('${tmp.path}/$name')..writeAsBytesSync(bytes)).path;

  /// White page with coloured 9×9 markers centred on the given points.
  img.Image markers(int w, int h, Map<(int, int), img.Color> at) {
    final im = img.Image(width: w, height: h)..clear(img.ColorRgb8(255, 255, 255));
    at.forEach((p, c) => img.fillRect(im, x1: p.$1 - 4, y1: p.$2 - 4, x2: p.$1 + 4, y2: p.$2 + 4, color: c));
    return im;
  }

  final red = img.ColorRgb8(220, 0, 0), green = img.ColorRgb8(0, 200, 0), blue = img.ColorRgb8(0, 0, 220), black = img.ColorRgb8(0, 0, 0);

  (int, int) render(String src, {List<double>? corners, int turns = 0, PageFilter filter = PageFilter.original, int maxEdge = 4000}) =>
      renderSync((src: src, out: '${tmp.path}/out.jpg', corners: corners, turns: turns, filter: filter, maxEdge: maxEdge, quality: 95));

  img.Image output() => img.decodeJpg(File('${tmp.path}/out.jpg').readAsBytesSync())!;

  /// Which marker colour dominates near (x, y).
  String colourAt(img.Image im, int x, int y) {
    final p = im.getPixel(x, y);
    if (p.r < 80 && p.g < 80 && p.b < 80) return 'black';
    if (p.r > 150 && p.g < 100) return 'red';
    if (p.g > 150 && p.r < 100) return 'green';
    if (p.b > 150 && p.r < 100) return 'blue';
    return 'white';
  }

  test('perspective crop puts each quad corner in the matching output corner', () {
    // A tilted quad inside a 400×300 photo.
    const quad = [(60, 40), (340, 70), (320, 260), (50, 230)];
    final src = write(
      'a.jpg',
      img.encodeJpg(markers(400, 300, {quad[0]: red, quad[1]: green, quad[2]: blue, quad[3]: black}), quality: 100),
    );
    final (w, h) = render(
      src,
      corners: [
        for (final (x, y) in quad) ...[x / 400, y / 300],
      ],
    );
    // Output size is the longer of each pair of opposite edges.
    expect(w, closeTo(281, 2)); // top edge 340-60 with 30 rise ≈ 281.6
    expect(h, closeTo(190, 2)); // left edge ≈ 190.2
    final out = output();
    expect(
      [colourAt(out, 1, 1), colourAt(out, w - 2, 1), colourAt(out, w - 2, h - 2), colourAt(out, 1, h - 2)],
      ['red', 'green', 'blue', 'black'],
    );
  });

  test('rotation turns clockwise and swaps the output size', () {
    final src = write('a.jpg', img.encodeJpg(markers(200, 100, {(4, 4): red}), quality: 100));
    final expected = {0: (200, 100, 'TL'), 1: (100, 200, 'TR'), 2: (200, 100, 'BR'), 3: (100, 200, 'BL')};
    expected.forEach((turns, e) {
      final (w, h) = render(src, turns: turns);
      expect((w, h), (e.$1, e.$2), reason: 'turns $turns');
      final out = output();
      final corner = {'TL': (2, 2), 'TR': (w - 3, 2), 'BR': (w - 3, h - 3), 'BL': (2, h - 3)}[e.$3]!;
      expect(colourAt(out, corner.$1, corner.$2), 'red', reason: 'turns $turns: marker at ${e.$3}');
    });
  });

  test('output is capped at the preset long edge and never upscaled', () {
    final src = write('a.jpg', img.encodeJpg(markers(800, 600, {}), quality: 90));
    expect(render(src, maxEdge: 400), (400, 300));
    expect(render(src, maxEdge: 3000), (800, 600));
  });

  test('a big photo renders correctly through the shrink-while-decoding path', () {
    final photo = markers(1600, 1200, {});
    img.fillRect(photo, x1: 0, y1: 0, x2: 160, y2: 160, color: red); // ~20 px in the output: survives JPEG chroma
    img.fillRect(photo, x1: 1440, y1: 1040, x2: 1599, y2: 1199, color: blue);
    final src = write('a.jpg', img.encodeJpg(photo, quality: 95));
    expect(render(src, maxEdge: 200), (200, 150)); // 8× smaller: decodes at 1/4, then samples
    final out = output();
    expect(colourAt(out, 6, 6), 'red');
    expect(colourAt(out, 193, 143), 'blue');
    expect(colourAt(out, 100, 75), 'white');
  });

  test('renders carry no EXIF, even when the source had camera and GPS data', () {
    final photo = markers(64, 48, {})..exif.imageIfd['Make'] = img.IfdValueAscii('PhoneCo');
    final src = write('a.jpg', img.encodeJpg(photo, quality: 90));
    expect(_hasApp1(File(src).readAsBytesSync()), isTrue, reason: 'the fixture really has EXIF');
    render(src);
    expect(_hasApp1(File('${tmp.path}/out.jpg').readAsBytesSync()), isFalse);
  });

  test('EXIF orientation is honoured for size and pixels', () {
    final photo = markers(40, 20, {(4, 4): red})..exif.imageIfd.orientation = 6; // stored sideways, shown rotated 90° cw
    final bytes = img.encodeJpg(photo, quality: 100);
    expect(uprightSize(bytes), (20, 40));
    expect(render(write('a.jpg', bytes)), (20, 40));
    expect(colourAt(output(), 17, 2), 'red', reason: 'top-left of the stored image shows at top-right');
  });

  test('B&W keeps text black and paper white under uneven light', () {
    // Paper fading from 110 (shadow) to 235 (lit), with dark strokes on both sides.
    final page = img.Image(width: 640, height: 400);
    for (var x = 0; x < 640; x++) {
      final v = 110 + 125 * x ~/ 639;
      img.drawLine(page, x1: x, y1: 0, x2: x, y2: 399, color: img.ColorRgb8(v, v, v));
    }
    img.fillRect(page, x1: 40, y1: 180, x2: 200, y2: 186, color: img.ColorRgb8(30, 30, 30)); // in the shadow
    img.fillRect(page, x1: 440, y1: 180, x2: 600, y2: 186, color: img.ColorRgb8(70, 70, 70)); // in the light
    render(write('a.jpg', img.encodeJpg(page, quality: 100)), filter: PageFilter.bw);
    final out = output();
    int lum(int x, int y) => out.getPixel(x, y).r.toInt();
    expect(lum(120, 183), lessThan(60), reason: 'stroke in shadow');
    expect(lum(520, 183), lessThan(60), reason: 'stroke in light');
    expect(lum(120, 60), greaterThan(200), reason: 'shadowed paper');
    expect(lum(520, 60), greaterThan(200), reason: 'lit paper');
  });

  test('ingest turns PNG transparency into white JPEG and copies JPEG byte for byte', () {
    final png = img.Image(width: 30, height: 20, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
    img.fillRect(png, x1: 0, y1: 0, x2: 9, y2: 19, color: img.ColorRgba8(0, 0, 0, 255));
    expect(normalizeSync(write('s.png', img.encodePng(png)), '${tmp.path}/n.jpg'), (30, 20));
    final n = img.decodeJpg(File('${tmp.path}/n.jpg').readAsBytesSync())!;
    expect(n.getPixel(25, 10).r, greaterThan(245), reason: 'transparent became white, not black');
    expect(n.getPixel(3, 10).r, lessThan(20));

    final jpeg = img.encodeJpg(markers(10, 10, {}), quality: 80);
    normalizeSync(write('j.jpg', jpeg), '${tmp.path}/c.jpg');
    expect(File('${tmp.path}/c.jpg').readAsBytesSync(), jpeg);

    expect(() => normalizeSync(write('t.txt', 'not an image'.codeUnits), '${tmp.path}/x.jpg'), throwsA(anything));
  });

  test('ingest refuses absurdly large non-JPEG images instead of running out of memory', () {
    final huge = write('huge.png', img.encodePng(img.Image(width: 6000, height: 5000), level: 1)); // 30 MP, tiny file
    expect(() => normalizeSync(huge, '${tmp.path}/x.jpg'), throwsA(anything));
    expect(render(write('ok.jpg', img.encodeJpg(markers(64, 48, {}), quality: 80))), (64, 48), reason: 'the limit is not left lowered');
  });

  test('render names are stable, file-name safe, and change with every input', () {
    final d = Document(id: 'd', dir: '/d', name: 'n', createdAt: DateTime(2026), updatedAt: DateTime(2026), pages: const []);
    const p = DocPage(id: 'p', src: 'src/a.jpg', w: 1, h: 1);
    final key = d.renderKey(p);
    expect(key, matches(RegExp(r'^\w{16}$')));
    expect(d.renderKey(p), key);
    expect(stableHash('abc'), stableHash('abc'));
    final variants = {
      d.renderKey(p.copyWith(turns: 1)),
      d.renderKey(p.copyWith(filter: PageFilter.bw)),
      d.renderKey(p.copyWith(corners: [0, 0, 1, 0, 1, 1, 0, 0.9])),
      d.renderKey(p.copyWith(src: 'src/b.jpg')),
      d.copyWith(quality: Quality.high).renderKey(p),
      key,
    };
    expect(variants, hasLength(6));
  });

  group('library renders', () {
    test('pages get rendered after a save, re-rendered after an edit, and the old render is removed', () async {
      final library = await Library.open('${tmp.path}/lib');
      final input = write('in.jpg', img.encodeJpg(markers(300, 200, {}), quality: 90));
      final d = (await ingest(library, [input])).doc!;
      await library.renderIdle();
      var page = library.byId(d.id)!.pages.single;
      final doc = library.byId(d.id)!;
      expect(doc.isRendered(page), isTrue);
      final first = '${d.dir}/${page.renderPath}';
      expect(File(first).existsSync(), isTrue);

      await library.save(doc.updatePage(0, page.copyWith(filter: PageFilter.bw, turns: 1)));
      expect(library.isRendering(library.byId(d.id)!, library.byId(d.id)!.pages.single), isTrue);
      await library.renderIdle();
      await library.flush();
      page = library.byId(d.id)!.pages.single;
      expect((page.w, page.h), (200, 300), reason: 'rotated render size');
      expect(File('${d.dir}/${page.renderPath}').existsSync(), isTrue);
      expect(File(first).existsSync(), isFalse, reason: 'replaced render deleted');
    });

    test('an edited page renders before the import backlog', () async {
      final library = await Library.open('${tmp.path}/lib');
      final inputs = [for (var i = 0; i < 5; i++) write('in$i.jpg', img.encodeJpg(markers(600, 400, {}), quality: 90))];
      final d = (await ingest(library, [inputs.first])).doc!;
      await library.renderIdle();
      final more = (await ingest(library, inputs.skip(1).toList(), into: d)).doc!; // 4 pages queued
      final edited = more.pages.first;
      library.save(more.updatePage(0, edited.copyWith(filter: PageFilter.bw)));
      // Under load some backlog renders finish before this point (ingest was still writing): only completions after the
      // edit count. Taken from byId after the save, so the edited page, whose render key just changed, isn't in it.
      final saved = library.byId(d.id)!;
      final before = {
        for (final p in saved.pages)
          if (saved.isRendered(p)) p.id,
      };
      final doneFirst = <String>[];
      void watch() {
        final now = library.byId(d.id)!;
        for (final p in now.pages) {
          if (now.isRendered(p) && !before.contains(p.id) && !doneFirst.contains(p.id)) doneFirst.add(p.id);
        }
      }

      library.addListener(watch);
      await library.renderIdle();
      library.removeListener(watch);
      // The render already in flight finishes first; the edited page goes next, ahead of the backlog.
      expect(doneFirst.take(2), contains(edited.id));
      // With fewer than two backlog pages left, finishing last is just as early as the edit can get.
      if (doneFirst.length > 2) expect(doneFirst.last, isNot(edited.id));
    });

    test('undo brings back a page whose shared render was deleted, and it renders again', () async {
      final library = await Library.open('${tmp.path}/lib');
      final d = (await ingest(library, [write('in.jpg', img.encodeJpg(markers(300, 200, {}), quality: 90))])).doc!;
      await library.renderIdle();
      final withCopy = library.byId(d.id)!.duplicatePage(0); // the copy shares the render file
      await library.save(withCopy);
      final copy = withCopy.pages[1];
      await library.save(withCopy.removePage(1)); // deleted, Undo pending
      final rotated = library.byId(d.id)!;
      await library.save(rotated.updatePage(0, rotated.pages.first.copyWith(turns: 1)));
      await library.renderIdle();
      await library.flush();
      final now = library.byId(d.id)!;
      await library.save(now.copyWith(pages: [...now.pages, copy])); // Undo
      await library.renderIdle();
      final restored = library.byId(d.id)!;
      expect(File(restored.pathOf(restored.pages.last)).existsSync(), isTrue);
    });

    test('editing one document retries only its own failed renders', () async {
      final library = await Library.open('${tmp.path}/lib');
      String src() => write('in${DateTime.now().microsecondsSinceEpoch}.jpg', img.encodeJpg(markers(30, 20, {}), quality: 90));
      final x = (await ingest(library, [src()])).doc!, y = (await ingest(library, [src()])).doc!;
      await library.renderIdle();
      final yDoc = library.byId(y.id)!;
      File('${y.dir}/${yDoc.pages.single.src}').writeAsBytesSync([1, 2, 3]); // Y's next render will fail
      await library.save(yDoc.updatePage(0, yDoc.pages.single.copyWith(filter: PageFilter.bw)));
      await library.renderIdle();
      await library.save(library.byId(x.id)!.copyWith(name: 'X renamed'));
      await library.renderIdle();
      final yNow = library.byId(y.id)!;
      expect(library.renderFailed(yNow, yNow.pages.single), isTrue, reason: 'Y keeps its error badge');
      expect(library.isRendering(yNow, yNow.pages.single), isFalse, reason: 'and no endless progress bar');
    });

    test('a page whose source is unreadable stops showing progress', () async {
      final library = await Library.open('${tmp.path}/lib');
      final d = (await ingest(library, [write('in.jpg', img.encodeJpg(markers(30, 20, {}), quality: 90))])).doc!;
      await library.renderIdle();
      final doc = library.byId(d.id)!;
      File('${d.dir}/${doc.pages.single.src}').writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
      await library.save(doc.updatePage(0, doc.pages.single.copyWith(filter: PageFilter.grayscale)));
      await library.renderIdle();
      final now = library.byId(d.id)!;
      expect(library.isRendering(now, now.pages.single), isFalse);
      expect(library.renderFailed(now, now.pages.single), isTrue);
    });

    test('rendered() renders its own document first and does not wait for another one’s backlog', () async {
      final library = await Library.open('${tmp.path}/lib');
      final small = img.encodeJpg(markers(60, 40, {}), quality: 90);
      final big = img.encodeJpg(markers(2400, 1800, {}), quality: 90);
      final b = (await ingest(library, [write('b0.jpg', small)])).doc!;
      await library.renderIdle();
      // A's import backlog: 8 big pages, rendered one at a time.
      final a = (await ingest(library, [for (var i = 0; i < 8; i++) write('a$i.jpg', big)])).doc!;
      var idle = false;
      library.renderIdle().then((_) => idle = true);
      bool allRendered(Document d) => d.pages.every((p) => d.isRendered(p) && File(d.pathOf(p)).existsSync());
      bool backlog() => library.byId(a.id)!.pages.any((p) => library.isRendering(library.byId(a.id)!, p));

      // B is finished: it exports at once.
      expect(allRendered((await library.rendered(b.id))!), isTrue);
      expect(idle, isFalse, reason: 'A is still rendering');

      // B gets a page that queues behind A's backlog: it jumps the queue.
      await ingest(library, [write('b1.jpg', small)], into: library.byId(b.id)!);
      expect(allRendered((await library.rendered(b.id))!), isTrue);
      expect(backlog(), isTrue, reason: 'A still has pages waiting');
      expect(idle, isFalse);

      // And A, asked for last, is still complete when it comes back.
      expect(allRendered((await library.rendered(a.id))!), isTrue);
      expect(backlog(), isFalse);
    });

    test('rendered() returns once its own in-flight page is done, not after another document’s next page', () async {
      final library = await Library.open('${tmp.path}/lib');
      final big = img.encodeJpg(markers(2400, 1800, {}), quality: 90);
      final b = (await ingest(library, [write('b.jpg', big)])).doc!;
      await library.renderIdle();
      final a = (await ingest(library, [for (var i = 0; i < 4; i++) write('a$i.jpg', big)])).doc!;
      final bDoc = library.byId(b.id)!;
      await library.save(bDoc.updatePage(0, bDoc.pages.single.copyWith(filter: PageFilter.grayscale)));
      int doneA() => library.byId(a.id)!.pages.where(library.byId(a.id)!.isRendered).length;
      // When an A page finishes, B's edited page is picked next: export B while it is in flight.
      final turn = Completer<void>();
      void onRender() => doneA() > 0 && !turn.isCompleted ? turn.complete() : null;
      library.addListener(onRender);
      await turn.future;
      library.removeListener(onRender);
      final before = doneA();
      final ready = (await library.rendered(b.id))!;
      expect(ready.isRendered(ready.pages.single), isTrue);
      expect(doneA(), before, reason: 'no page of A rendered while B was being waited for');
      await library.renderIdle();
    });

    test('rendered() retries a failed render and re-creates a missing render file', () async {
      final library = await Library.open('${tmp.path}/lib');
      final good = img.encodeJpg(markers(30, 20, {}), quality: 90);
      final d = (await ingest(library, [write('a.jpg', good), write('b.jpg', good)])).doc!;
      await library.renderIdle();
      final doc = library.byId(d.id)!;
      final [a, b] = doc.pages;
      File('${d.dir}/${a.src}').writeAsBytesSync([1, 2, 3]);
      await library.save(doc.updatePage(0, a.copyWith(filter: PageFilter.grayscale)));
      await library.renderIdle();
      expect(library.renderFailed(library.byId(d.id)!, library.byId(d.id)!.pages.first), isTrue);
      File('${d.dir}/${a.src}').writeAsBytesSync(good); // whatever broke it is gone now
      File(doc.pathOf(b)).deleteSync(); // and the other page's render file went missing

      final ready = (await library.rendered(d.id))!;
      for (final p in ready.pages) {
        expect(ready.isRendered(p) && File(ready.pathOf(p)).existsSync(), isTrue, reason: p.id);
      }
    });
  });
}

bool _hasApp1(Uint8List jpeg) {
  for (var i = 2; i + 3 < jpeg.length;) {
    if (jpeg[i] != 0xFF) return false;
    final marker = jpeg[i + 1];
    if (marker == 0xE1) return true;
    if (marker == 0xDA) return false; // start of scan: no more metadata segments
    i += 2 + (jpeg[i + 2] << 8 | jpeg[i + 3]);
  }
  return false;
}
