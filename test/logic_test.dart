import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/document.dart';
import 'package:folio/library.dart';
import 'package:folio/pdf.dart';
import 'package:folio/render.dart';

DocPage page(String id, {int w = 1240, int h = 1754, int turns = 0}) => DocPage(id: id, src: 'src/$id.jpg', w: w, h: h, turns: turns);

Document doc(List<DocPage> pages, {String name = 'Doc', DocKind kind = DocKind.document, PageSize size = PageSize.fit, DateTime? at}) =>
    Document(
      id: newId(),
      dir: '/tmp',
      name: name,
      kind: kind,
      pageSize: size,
      createdAt: at ?? DateTime(2026),
      updatedAt: at ?? DateTime(2026),
      pages: pages,
    );

void main() {
  test('page ops keep order consistent', () {
    final d = doc([page('a'), page('b'), page('c')]);
    String ids(Document d) => d.pages.map((p) => p.id).join();
    expect(ids(d.movePage(0, 2)), 'bca');
    expect(ids(d.movePage(2, 0)), 'cab');
    expect(ids(d.removePage(1)), 'ac');
    final dup = d.duplicatePage(0);
    expect(dup.pages.length, 4);
    expect(dup.pages[1].src, dup.pages[0].src);
    expect(dup.pages[1].id, isNot(dup.pages[0].id));
    final rendered = doc([page('a').copyWith(r: 'h1')]).duplicatePage(0);
    expect(rendered.pages[1].renderPath, rendered.pages[0].renderPath, reason: 'a duplicate shares the render file');
  });

  test('library search is case-insensitive and sorts', () {
    final lib = Library(
      '/unused',
      docs: [
        doc([page('a')], name: 'Lease agreement', at: DateTime(2026, 1)),
        doc([page('b')], name: 'bill', at: DateTime(2026, 3)),
      ],
    );
    expect(lib.query('LEASE', DocSort.recent).map((d) => d.name), ['Lease agreement']);
    expect(lib.query('', DocSort.recent).map((d) => d.name), ['bill', 'Lease agreement']);
    expect(lib.query('', DocSort.name).map((d) => d.name), ['bill', 'Lease agreement']);
  });

  test('squareToQuad maps unit corners onto the quad', () {
    const q = [0.1, 0.05, 0.9, 0.12, 0.95, 0.9, 0.02, 0.97];
    final [a, b, c, d, e, f, g, h] = squareToQuad(q);
    for (final (i, (u, v)) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].indexed) {
      final z = g * u + h * v + 1;
      expect((a * u + b * v + c) / z, closeTo(q[i * 2], 1e-9));
      expect((d * u + e * v + f) / z, closeTo(q[i * 2 + 1], 1e-9));
    }
  });

  test('isConvex rejects bow-ties and accepts real quads', () {
    expect(isConvex([0, 0, 1, 0, 1, 1, 0, 1]), isTrue);
    expect(isConvex([0.1, 0.05, 0.9, 0.12, 0.95, 0.9, 0.02, 0.97]), isTrue);
    expect(isConvex([0, 0, 1, 1, 1, 0, 0, 1]), isFalse);
    expect(isConvex([1, 0, 0, 0, 0, 1, 1, 1]), isFalse, reason: 'convex but mirrored: handles dragged past each other');
  });

  group('layout', () {
    test('fit: A4 width, height follows the image, no margin', () {
      final [p] = layout(doc([page('a', w: 600, h: 1800)]));
      expect(p.size.width, closeTo(595.28, 0.01));
      expect(p.size.height, closeTo(595.28 * 3, 0.01));
      expect(p.images.single.$2, Offset.zero & p.size);
    });

    test('A4: landscape image gets a landscape page, centred inside 10 mm margins', () {
      final [p] = layout(doc([page('a', w: 2000, h: 1000)], size: PageSize.a4));
      expect(p.size.width, greaterThan(p.size.height));
      final r = p.images.single.$2;
      expect(r.left, closeTo(10 * mm, 0.01));
      expect(r.center.dx, closeTo(p.size.width / 2, 0.01));
      expect(r.center.dy, closeTo(p.size.height / 2, 0.01));
    });

    test('rotation swaps image dimensions', () {
      final [p] = layout(doc([page('a', w: 2000, h: 1000, turns: 1)], size: PageSize.a4));
      expect(p.size.height, greaterThan(p.size.width));
    });

    test('ID card: ID-1 sides print at 85.6 mm, stacked on one page', () {
      final [p] = layout(doc([page('f', w: 1011, h: 638), page('b', w: 1011, h: 638)], kind: DocKind.idCard, size: PageSize.a4));
      expect(p.images.length, 2);
      for (final (_, r) in p.images) {
        expect(r.width, closeTo(85.6 * mm, 0.01));
      }
      expect(p.images[1].$2.top - p.images[0].$2.bottom, closeTo(12 * mm, 0.01));
    });

    test('ID card: vertical ID-1 sides keep real size and fit inside Letter margins', () {
      final [p] = layout(doc([page('f', w: 638, h: 1011), page('b', w: 638, h: 1011)], kind: DocKind.idCard, size: PageSize.letter));
      expect([p.size.width, p.size.height], [612, 792], reason: 'PRD I2: an ID card prints on Letter when chosen');
      expect(p.images.first.$2.height, closeTo(85.6 * mm, 0.01));
      expect(p.images.first.$2.top, greaterThanOrEqualTo(10 * mm));
      expect(p.images.last.$2.bottom, lessThanOrEqualTo(p.size.height - 10 * mm));
    });

    // ID-1 is 85.6 x 54 mm: a vertical side is the same card turned, so it also gets a 85.6 mm long edge.
    test('ID card: mixed orientation, each side keeps its 85.6 mm long edge and is centred, 12 mm apart', () {
      // The back is at half the resolution: a vertical side wrongly taken for non-ID-1 would shrink to 42.8 mm.
      final [p] = layout(doc([page('f', w: 1011, h: 638), page('b', w: 319, h: 506)], kind: DocKind.idCard, size: PageSize.a4));
      final [(_, front), (_, back)] = p.images;
      expect(front.width, closeTo(85.6 * mm, 0.01), reason: 'horizontal: long edge is the width');
      expect(back.height, closeTo(85.6 * mm, 0.01), reason: 'vertical: long edge is the height');
      expect(front.center.dx, closeTo(p.size.width / 2, 0.01));
      expect(back.center.dx, closeTo(p.size.width / 2, 0.01));
      expect(back.top - front.bottom, closeTo(12 * mm, 0.01));
    });

    test('ID card: a ratio 5.9 % off ID-1 still counts as ID-1, 7 % off does not (PRD I2: within 6 %)', () {
      // The other side is a big square, so a side sharing its scale would come out smaller than 85.6 mm.
      final square = page('s', w: 2000, h: 2000);
      PageLayout two(int w) => layout(
        doc(
          [page('c', w: w, h: 1000), square],
          kind: DocKind.idCard,
          size: PageSize.a4,
        ),
      ).single;

      final near = two((1586 * 1.059).round()); // ratio 1.680
      expect(near.images[0].$2.width, closeTo(85.6 * mm, 0.01), reason: 'ID-1-like: real size');
      expect(near.images[1].$2.width, closeTo(85.6 * mm, 0.01));

      final far = two((1586 * 1.07).round()); // ratio 1.697
      expect(far.images[0].$2.width, closeTo(85.6 * mm * 1697 / 2000, 0.01), reason: 'not ID-1: shares the square’s scale');
      expect(far.images[1].$2.width, closeTo(85.6 * mm, 0.01));
    });

    test('ID card: one side alone is centred on the page at real size', () {
      final [p] = layout(doc([page('f', w: 1011, h: 638)], kind: DocKind.idCard, size: PageSize.a4));
      final r = p.images.single.$2;
      expect(r.width, closeTo(85.6 * mm, 0.01));
      expect(r.center.dx, closeTo(p.size.width / 2, 0.01));
      expect(r.center.dy, closeTo(p.size.height / 2, 0.01));
    });

    test('ID card: Fit prints as A4', () {
      final sides = [page('f', w: 1011, h: 638), page('b', w: 1011, h: 638)];
      final [fit] = layout(doc(sides, kind: DocKind.idCard, size: PageSize.fit));
      final [a4] = layout(doc(sides, kind: DocKind.idCard, size: PageSize.a4));
      expect(fit.size.width, closeTo(595.28, 0.01));
      expect(fit.size.height, closeTo(841.89, 0.01));
      expect(fit.size, a4.size);
      expect([for (final (_, r) in fit.images) r], [for (final (_, r) in a4.images) r]);
    });

    // Every side's long edge is capped at 85.6 mm, so two stacked are at most 2 x 85.6 + 12 = 183.2 mm tall and
    // 85.6 mm wide: far inside A4 (277 mm x 190 mm printable) and Letter (259 mm x 195 mm). The shrink-to-fit
    // branch in _idCard is a guard that cannot trigger with two sides; this pins that, so a change to the cap
    // or the gap that breaks it shows up here.
    test('ID card: two tall sides stay at real size inside the margins on A4 and Letter', () {
      for (final size in [PageSize.a4, PageSize.letter]) {
        for (final (w, h) in [(638, 1011), (400, 2000)]) {
          final [p] = layout(
            doc(
              [page('f', w: w, h: h), page('b', w: w, h: h)],
              kind: DocKind.idCard,
              size: size,
            ),
          );
          for (final (_, r) in p.images) {
            expect(r.longestSide, closeTo(85.6 * mm, 0.01), reason: '$size ${w}x$h');
          }
          expect(p.images.first.$2.top, greaterThanOrEqualTo(10 * mm), reason: '$size ${w}x$h');
          expect(p.images.last.$2.bottom, lessThanOrEqualTo(p.size.height - 10 * mm), reason: '$size ${w}x$h');
        }
      }
    });

    test('ID card: non-ID-1 cards share one scale', () {
      final [p] = layout(doc([page('f', w: 1000, h: 1000), page('b', w: 500, h: 500)], kind: DocKind.idCard, size: PageSize.a4));
      expect(p.images[0].$2.width, closeTo(85.6 * mm, 0.01));
      expect(p.images[1].$2.width, closeTo(42.8 * mm, 0.01));
    });
  });

  test('ID-card renders are 1100 px on the long edge at every quality', () {
    for (final q in Quality.values) {
      expect(
        doc([page('a')], kind: DocKind.idCard).copyWith(quality: q).renderPreset.$1,
        1100,
        reason: q.name,
      );
    }
  });

  // PRD §6 and I4: paths and document content never reach a log.
  test('the app writes nothing to any log', () {
    final logging = RegExp(r'\bprint\(|debugPrint|debugPrintStack|dart:developer|\blog\(|\bstdout\b|\bstderr\b');
    for (final f in Directory('lib').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(logging.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });
}
