import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:folio/document.dart';
import 'package:folio/render.dart';

/// Paints a believable library on the device so screenshots show real-looking paper, with no demo code in the app.
/// The documents are written to disk; opening them with Library.open runs the real render pipeline.
const _ink = Color(0xFF1D2233);
const _serif = ['Georgia', 'serif'];
const _mono = ['Courier', 'monospace'];
const _hand = ['Noteworthy', 'Bradley Hand', 'casual'];

class Fixtures {
  Fixtures(this.docs, this.idFront, this.damaged);

  final List<Document> docs;
  final String idFront;
  final Document damaged;
}

Future<Fixtures> buildFixtures(String root) async {
  final now = DateTime.now();
  Future<Document> make(
    String name,
    Duration ago,
    List<Future<DocPage> Function(String dir)> pages, {
    DocKind kind = DocKind.document,
    PageFilter? filter,
  }) async {
    final id = newId(), dir = '$root/$id';
    await Directory('$dir/src').create(recursive: true);
    await Directory('$dir/cache').create();
    final list = [for (final p in pages) await p(dir)];
    final at = now.subtract(ago);
    final doc = Document(
      id: id,
      dir: dir,
      name: name,
      kind: kind,
      createdAt: at,
      updatedAt: at,
      pages: [for (final p in list) filter == null ? p : p.copyWith(filter: filter)],
    );
    // On disk like a real library, so Library.open loads it and renders every page for real.
    await File('$dir/doc.json').writeAsString(jsonEncode(doc.toJson()));
    return doc;
  }

  Future<DocPage> Function(String) sheet(Size size, void Function(Canvas, Size) draw, {Color paper = Colors.white}) => (dir) async {
    final id = newId();
    final (w, h) = await _png('$dir/src/$id.jpg', size, draw, paper);
    return DocPage(id: id, src: 'src/$id.jpg', w: w, h: h);
  };

  const a4 = Size(1240, 1754);
  final docs = [
    await make('Lease agreement, 12 Harbour Lane', const Duration(minutes: 18), [
      sheet(a4, (c, s) => _lease(c, s, 1)),
      sheet(a4, (c, s) => _lease(c, s, 2)),
      sheet(a4, (c, s) => _lease(c, s, 3)),
      (dir) => _photographed(dir, a4, (c, s) => _lease(c, s, 4)),
    ]),
    await make('Electricity bill, October', const Duration(hours: 3), [
      sheet(a4, (c, s) => _bill(c, s, 1)),
      sheet(a4, (c, s) => _bill(c, s, 2)),
    ]),
    await make('Linear algebra notes', const Duration(days: 1, hours: 2), [
      for (var i = 1; i <= 3; i++) sheet(a4, (c, s) => _notes(c, s, i), paper: const Color(0xFFFFFEF7)),
    ], filter: PageFilter.enhance),
    await make('Grocery receipt', const Duration(days: 2, hours: 5), [sheet(const Size(620, 1560), _receipt)]),
    await make('Business card, Mara Lindqvist', const Duration(days: 6), [sheet(const Size(1050, 600), _businessCard)]),
    await make('Library card', const Duration(days: 27), [
      sheet(const Size(1011, 638), (c, s) => _libraryCard(c, s, front: true)),
      sheet(const Size(1011, 638), (c, s) => _libraryCard(c, s, front: false)),
    ], kind: DocKind.idCard),
  ];
  final idFront = '$root/id_front.jpg';
  await _png(idFront, const Size(1011, 638), (c, s) => _libraryCard(c, s, front: true), Colors.white);
  final damaged = Document(
    id: newId(),
    dir: '$root/broken',
    name: 'Tax return 2025',
    createdAt: now,
    updatedAt: now,
    pages: const [],
    damaged: true,
  );
  return Fixtures(docs, idFront, damaged);
}

Future<(int, int)> _png(String path, Size size, void Function(Canvas, Size) draw, Color paper) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec)..drawRect(Offset.zero & size, Paint()..color = paper);
  draw(c, size);
  final img = await rec.endRecording().toImage(size.width.round(), size.height.round());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  return (img.width, img.height);
}

double _text(
  Canvas c,
  String s,
  Offset at, {
  double size = 21,
  FontWeight weight = FontWeight.w400,
  Color color = _ink,
  double? width,
  List<String> family = const [],
  double height = 1.5,
  TextAlign align = TextAlign.left,
  FontStyle style = FontStyle.normal,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        fontStyle: style,
        fontFamily: family.firstOrNull,
        fontFamilyFallback: family,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(minWidth: width ?? 0, maxWidth: width ?? 4000);
  tp.paint(c, at);
  return tp.height;
}

void _rule(Canvas c, Offset a, Offset b, {Color color = _ink, double w = 1.4}) => c.drawLine(
  a,
  b,
  Paint()
    ..color = color
    ..strokeWidth = w,
);

const _clauses = [
  (
    'Parties',
    'This agreement is made between Harbour Lane Properties Ltd (the Landlord) and Mara Lindqvist (the Tenant) for the residential premises described below.',
  ),
  (
    'Premises',
    'Flat 3, 12 Harbour Lane, including the fixtures, fittings and furnishings listed in the attached inventory, which forms part of this agreement.',
  ),
  (
    'Term',
    'The tenancy begins on 1 November 2026 and continues for a fixed term of twelve months, after which it becomes a periodic tenancy unless either party gives notice.',
  ),
  (
    'Rent',
    'The rent is 1,450.00 per calendar month, payable in advance on the first day of each month by standing order to the account named in Schedule 2.',
  ),
  (
    'Deposit',
    'A deposit equal to five weeks of rent is held in a government-approved protection scheme and returned within ten days of the end of the tenancy, less agreed deductions.',
  ),
  (
    'Repairs',
    'The Landlord keeps the structure, exterior and installations for water, gas, electricity and heating in repair. The Tenant reports any defect promptly in writing.',
  ),
  (
    'Use of the premises',
    'The Tenant uses the premises as a single private dwelling and does not carry on any trade or business from them without written consent.',
  ),
  (
    'Access',
    'The Landlord may enter at reasonable times to inspect or carry out repairs after giving at least twenty-four hours of written notice, except in an emergency.',
  ),
  (
    'Ending the tenancy',
    'Either party may end the periodic tenancy by giving the notice required by law. The Tenant returns all keys on the last day of the tenancy.',
  ),
];

void _lease(Canvas c, Size s, int page) {
  const m = 130.0;
  final w = s.width - 2 * m;
  var y = 150.0;
  if (page == 1) {
    y += _text(c, 'Residential Lease Agreement', Offset(m, y), size: 50, weight: FontWeight.w700, family: _serif, height: 1.2);
    y +=
        6 +
        _text(
          c,
          'Assured shorthold tenancy  ·  Flat 3, 12 Harbour Lane',
          Offset(m, y),
          size: 22,
          color: const Color(0xFF59607A),
          family: _serif,
        );
    y += 24;
    _rule(c, Offset(m, y), Offset(s.width - m, y), w: 2.4);
    y += 40;
  }
  if (page == 4) {
    y += _text(c, 'Signatures', Offset(m, y), size: 34, weight: FontWeight.w700, family: _serif) + 18;
    y +=
        _text(
          c,
          'By signing below, both parties confirm that they have read and agree to the terms of this agreement and its schedules.',
          Offset(m, y),
          width: w,
          family: _serif,
        ) +
        70;
    for (final (role, name, sign) in [
      ('Landlord', 'For Harbour Lane Properties Ltd', 'J. Okafor'),
      ('Tenant', 'Mara Lindqvist', 'Mara Lindqvist'),
    ]) {
      _text(c, sign, Offset(m + 20, y), size: 52, family: _hand, color: const Color(0xFF1F3A8A), style: FontStyle.italic);
      y += 76;
      _rule(c, Offset(m, y), Offset(m + 560, y));
      _rule(c, Offset(m + 660, y), Offset(s.width - m, y));
      _text(c, '$role: $name', Offset(m, y + 10), size: 19, color: const Color(0xFF59607A), family: _serif);
      _text(c, 'Date: 24 October 2026', Offset(m + 660, y + 10), size: 19, color: const Color(0xFF59607A), family: _serif);
      y += 150;
    }
  } else {
    for (var i = (page - 1) * 3; i < min(page * 3, _clauses.length); i++) {
      final (title, body) = _clauses[i];
      y += _text(c, '${i + 1}.  $title', Offset(m, y), size: 25, weight: FontWeight.w700, family: _serif) + 8;
      for (var k = 0; k < 2; k++) {
        y +=
            _text(
              c,
              k == 0
                  ? body
                  : '$body The parties agree that this clause is read together with the schedules and any written variations signed by both of them.',
              Offset(m, y),
              width: w,
              family: _serif,
            ) +
            18;
      }
      y += 26;
    }
  }
  _text(
    c,
    'Page $page of 4',
    Offset(0, s.height - 110),
    width: s.width,
    align: TextAlign.center,
    size: 18,
    color: const Color(0xFF7A8195),
    family: _serif,
  );
}

void _bill(Canvas c, Size s, int page) {
  const m = 110.0, green = Color(0xFF0F6B4F);
  c.drawRect(Rect.fromLTWH(0, 0, s.width, 210), Paint()..color = green);
  c.drawCircle(const Offset(m + 34, 105), 34, Paint()..color = const Color(0xFFB9F0D6));
  _text(c, 'Northgrid Energy', const Offset(m + 88, 74), size: 40, weight: FontWeight.w700, color: Colors.white);
  _text(
    c,
    page == 1 ? 'Your electricity statement' : 'Usage details',
    Offset(s.width - m - 460, 84),
    width: 460,
    align: TextAlign.right,
    size: 24,
    color: const Color(0xFFDDF7EA),
  );
  var y = 280.0;
  if (page == 1) {
    _text(c, 'Mara Lindqvist\nFlat 3, 12 Harbour Lane\nPort Ellery PE4 2RL', Offset(m, y), size: 22, height: 1.55);
    _text(
      c,
      'Account  4471 0938 22\nStatement date  14 Oct 2026\nPeriod  14 Sep – 13 Oct 2026',
      Offset(s.width - m - 470, y),
      width: 470,
      align: TextAlign.right,
      size: 22,
      height: 1.55,
    );
    y += 190;
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(m, y, s.width - 2 * m, 210), const Radius.circular(18));
    c.drawRRect(box, Paint()..color = const Color(0xFFEAF7F1));
    _text(c, 'Amount due', Offset(m + 40, y + 40), size: 24, color: green);
    _text(c, '84.12', Offset(m + 40, y + 78), size: 72, weight: FontWeight.w700, color: green, height: 1.1);
    _text(
      c,
      'Paid by direct debit on\n28 October 2026',
      Offset(s.width - m - 400, y + 70),
      width: 360,
      align: TextAlign.right,
      size: 22,
      color: green,
    );
    y += 290;
  }
  final rows = page == 1
      ? [('Electricity used', '312 kWh', '71.24'), ('Standing charge', '30 days', '15.12'), ('Discount', 'Online billing', '-2.24')]
      : [
          for (var d = 0; d < 14; d++)
            ('${14 + d} Sep', '${8 + (d * 7) % 9}.${(d * 3) % 10} kWh', (2 + (d * 7) % 9 * 0.23).toStringAsFixed(2)),
        ];
  _text(c, page == 1 ? 'Summary' : 'Daily usage', Offset(m, y), size: 30, weight: FontWeight.w700);
  y += 64;
  for (final (a, b, v) in rows) {
    _text(c, a, Offset(m, y), size: 22);
    _text(c, b, Offset(m + 520, y), size: 22, color: const Color(0xFF59607A));
    _text(c, v, Offset(s.width - m - 200, y), width: 200, align: TextAlign.right, size: 22);
    y += 50;
    _rule(c, Offset(m, y - 10), Offset(s.width - m, y - 10), color: const Color(0xFFDDE1E8), w: 1);
  }
  if (page == 1) {
    y += 20;
    _text(c, 'Total', Offset(m, y), size: 24, weight: FontWeight.w700);
    _text(c, '84.12', Offset(s.width - m - 200, y), width: 200, align: TextAlign.right, size: 24, weight: FontWeight.w700);
  }
  _text(
    c,
    'northgrid.example  ·  Questions? 0800 000 4471',
    Offset(0, s.height - 100),
    width: s.width,
    align: TextAlign.center,
    size: 18,
    color: const Color(0xFF7A8195),
  );
}

void _notes(Canvas c, Size s, int page) {
  for (var y = 180.0; y < s.height - 60; y += 58) {
    _rule(c, Offset(0, y), Offset(s.width, y), color: const Color(0xFFB9D4F0), w: 1.6);
  }
  _rule(c, const Offset(150, 0), Offset(150, s.height), color: const Color(0xFFF2A3A3), w: 2);
  const blue = Color(0xFF1F3A8A);
  final lines = switch (page) {
    1 => [
      'Lecture 7: Eigenvalues',
      '',
      'A v = λ v   for v ≠ 0',
      'λ is an eigenvalue, v an eigenvector',
      '',
      'Find them: det(A − λI) = 0',
      '→ characteristic polynomial',
      '',
      'Example  A = [2 1; 1 2]',
      'det = (2−λ)² − 1 = 0',
      'λ = 1  or  λ = 3',
    ],
    2 => [
      'Diagonalisation',
      '',
      'If A has n independent eigenvectors:',
      'A = P D P⁻¹',
      'D = diag(λ₁ … λₙ)',
      '',
      'Then Aᵏ = P Dᵏ P⁻¹  (cheap!)',
      '',
      'Symmetric A → orthogonal P',
      'P⁻¹ = Pᵀ',
    ],
    _ => [
      'Practice',
      '',
      '1. Eigenvalues of [4 1; 2 3]',
      '2. Show trace = Σλ, det = Πλ',
      '3. Is [1 1; 0 1] diagonalisable?',
      '',
      'Exam: Thu 12 Nov, room B204',
    ],
  };
  for (final (i, l) in lines.indexed) {
    _text(
      c,
      l,
      Offset(180, 128 + i * 58.0),
      size: i == 0 ? 44 : 34,
      family: _hand,
      color: blue,
      weight: i == 0 ? FontWeight.w700 : FontWeight.w400,
      height: 1.2,
    );
  }
  if (page == 1) {
    final o = Offset(s.width - 330, 1280);
    final p = Paint()
      ..color = blue
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawLine(o, o.translate(220, 0), p);
    c.drawLine(o, o.translate(0, -220), p);
    c.drawLine(o, o.translate(150, -150), p..color = const Color(0xFFC0392B));
    c.drawLine(o, o.translate(160, -60), p..color = blue);
    _text(c, 'v', o.translate(160, -200), size: 34, family: _hand, color: const Color(0xFFC0392B));
  }
}

void _receipt(Canvas c, Size s) {
  const m = 46.0;
  final w = s.width - 2 * m;
  var y = 70.0;
  y += _text(c, 'FRESHFIELD MARKET', Offset(m, y), width: w, align: TextAlign.center, size: 34, weight: FontWeight.w700, family: _mono);
  y +=
      _text(c, '48 Quay Street, Port Ellery\nTel 01632 960 118', Offset(m, y), width: w, align: TextAlign.center, size: 20, family: _mono) +
      30;
  final items = [
    ('Sourdough loaf', '3.40'),
    ('Oat milk 1L', '1.85'),
    ('Free range eggs x6', '2.60'),
    ('Bananas 1.1kg', '1.21'),
    ('Cheddar 400g', '4.10'),
    ('Basmati rice 1kg', '2.95'),
    ('Tomatoes vine', '2.25'),
    ('Coffee beans 250g', '6.50'),
    ('Spinach 200g', '1.60'),
    ('Dark chocolate', '1.95'),
  ];
  for (final (a, b) in items) {
    _text(c, a, Offset(m, y), size: 22, family: _mono);
    _text(c, b, Offset(m, y), width: w, align: TextAlign.right, size: 22, family: _mono);
    y += 40;
  }
  y += 10;
  _text(c, '- ' * 22, Offset(m, y), size: 22, family: _mono);
  y += 44;
  for (final (a, b, bold) in [('SUBTOTAL', '28.41', false), ('TOTAL', '28.41', true), ('CARD ****4471', '28.41', false)]) {
    _text(c, a, Offset(m, y), size: bold ? 30 : 22, weight: bold ? FontWeight.w700 : FontWeight.w400, family: _mono);
    _text(
      c,
      b,
      Offset(m, y),
      width: w,
      align: TextAlign.right,
      size: bold ? 30 : 22,
      weight: bold ? FontWeight.w700 : FontWeight.w400,
      family: _mono,
    );
    y += bold ? 54 : 40;
  }
  y += 40;
  final r = Random(7);
  for (var x = m + 40; x < s.width - m - 40; x += 4 + r.nextInt(5)) {
    c.drawRect(Rect.fromLTWH(x, y, 2.0 + r.nextInt(4), 110), Paint()..color = _ink);
  }
  y += 140;
  _text(
    c,
    '24/10/2026 18:42  TILL 3\nThank you for shopping with us',
    Offset(m, y),
    width: w,
    align: TextAlign.center,
    size: 20,
    family: _mono,
  );
}

void _businessCard(Canvas c, Size s) {
  const accent = Color(0xFF8A3B12);
  c.drawRect(Rect.fromLTWH(0, 0, 22, s.height), Paint()..color = accent);
  _text(c, 'Mara Lindqvist', const Offset(90, 120), size: 64, weight: FontWeight.w700, family: _serif, height: 1.1);
  _text(c, 'Product Designer', const Offset(92, 210), size: 30, color: accent);
  _text(
    c,
    'mara@lindqvist.example\n+44 7700 900 418\nlindqvist.example',
    const Offset(92, 360),
    size: 26,
    height: 1.6,
    color: const Color(0xFF3B4152),
  );
  _text(
    c,
    'Studio Lindqvist',
    Offset(s.width - 420, 470),
    width: 360,
    align: TextAlign.right,
    size: 24,
    weight: FontWeight.w600,
    color: const Color(0xFF59607A),
  );
}

void _libraryCard(Canvas c, Size s, {required bool front}) {
  const teal = Color(0xFF0E5E6F);
  c.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(36)), Paint()..color = const Color(0xFFF4FAFB));
  if (front) {
    c.drawRRect(
      RRect.fromRectAndCorners(Rect.fromLTWH(0, 0, s.width, 150), topLeft: const Radius.circular(36), topRight: const Radius.circular(36)),
      Paint()..color = teal,
    );
    _text(c, 'Riverside Public Library', const Offset(60, 46), size: 44, weight: FontWeight.w700, color: Colors.white);
    final photo = RRect.fromRectAndRadius(const Rect.fromLTWH(60, 200, 230, 290), const Radius.circular(16));
    c.drawRRect(photo, Paint()..color = const Color(0xFFCFDDE2));
    c.drawCircle(const Offset(175, 300), 58, Paint()..color = const Color(0xFF8FA9B2));
    c.drawOval(const Rect.fromLTWH(85, 380, 180, 160), Paint()..color = const Color(0xFF8FA9B2));
    _text(c, 'Mara Lindqvist', const Offset(340, 210), size: 46, weight: FontWeight.w700);
    _text(c, 'Member since 2021', const Offset(342, 280), size: 28, color: const Color(0xFF4C5568));
    _text(c, 'Card no.\n2049 3317 0042', const Offset(342, 360), size: 30, height: 1.35);
    _text(c, 'Valid to 09/2029', const Offset(342, 500), size: 26, color: const Color(0xFF4C5568));
  } else {
    c.drawRect(Rect.fromLTWH(0, 70, s.width, 110), Paint()..color = const Color(0xFF222632));
    _text(
      c,
      'If found, please return to any Riverside branch\nor post to 1 Mill Road, Port Ellery PE1 1AA.',
      const Offset(60, 220),
      size: 28,
      height: 1.45,
      color: const Color(0xFF3B4152),
    );
    final r = Random(3);
    for (var x = 60.0; x < 600; x += 5 + r.nextInt(6)) {
      c.drawRect(Rect.fromLTWH(x, 380, 2.0 + r.nextInt(5), 140), Paint()..color = _ink);
    }
    _text(c, '20493317004 2', const Offset(60, 528), size: 24, family: _mono);
    _rule(c, const Offset(660, 500), const Offset(950, 500), w: 2);
    _text(c, 'Signature', const Offset(660, 510), size: 22, color: const Color(0xFF59607A));
    _text(c, 'M. Lindqvist', const Offset(680, 420), size: 46, family: _hand, color: const Color(0xFF1F3A8A), style: FontStyle.italic);
  }
}

/// The last lease page as if photographed on a desk: perspective, shadow, warm wood. Corners match the paper.
Future<DocPage> _photographed(String dir, Size page, void Function(Canvas, Size) draw) async {
  final id = newId();
  final rec = ui.PictureRecorder();
  draw(Canvas(rec)..drawRect(Offset.zero & page, Paint()..color = Colors.white), page);
  final flat = await rec.endRecording().toImage(page.width.round(), page.height.round());
  // The flat page doubles as the "rendered" output until M3a renders for real.
  final flatBytes = await flat.toByteData(format: ui.ImageByteFormat.png);
  await File('$dir/cache/fixture.jpg').writeAsBytes(flatBytes!.buffer.asUint8List());

  const photo = Size(1500, 2000);
  const q = [250.0, 300.0, 1270.0, 210.0, 1350.0, 1690.0, 170.0, 1780.0];
  final (w, h) = await _png('$dir/src/$id.jpg', photo, (c, s) {
    c.drawRect(
      Offset.zero & s,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(s.width, s.height), [const Color(0xFF6B4A33), const Color(0xFF3E2A1D)]),
    );
    final grain = Random(11);
    for (var i = 0; i < 260; i++) {
      final y = grain.nextDouble() * s.height;
      c.drawLine(
        Offset(0, y),
        Offset(s.width, y + grain.nextDouble() * 40 - 20),
        Paint()
          ..color = const Color(0x14000000)
          ..strokeWidth = 1 + grain.nextDouble() * 3,
      );
    }
    final outline = Path()..addPolygon([for (var i = 0; i < 4; i++) Offset(q[i * 2], q[i * 2 + 1])], true);
    c.drawPath(
      outline.shift(const Offset(18, 26)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
    );
    final [a, b, cc, d, e, f, g, hh] = squareToQuad([for (final v in q) v]);
    final sx = 1 / page.width, sy = 1 / page.height;
    c.save();
    c.transform(Matrix4(a * sx, d * sx, 0, g * sx, b * sy, e * sy, 0, hh * sy, 0, 0, 1, 0, cc, f, 0, 1).storage);
    c.drawImage(flat, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    c.restore();
    c.drawPath(
      outline,
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(s.width, s.height), [const Color(0x00FFFFFF), const Color(0x22000000)]),
    );
  }, Colors.black);
  return DocPage(
    id: id,
    src: 'src/$id.jpg',
    r: 'fixture',
    w: page.width.round(),
    h: page.height.round(),
    corners: [for (var i = 0; i < 8; i++) q[i] / (i.isEven ? w : h)],
  );
}

/// Recursive copy, so each screenshot pass starts from the same rendered library.
Future<void> copyTree(String from, String to) async {
  await for (final e in Directory(from).list(recursive: true)) {
    final dest = '$to${e.path.substring(from.length)}';
    if (e is Directory) await Directory(dest).create(recursive: true);
    if (e is File) {
      await Directory(File(dest).parent.path).create(recursive: true);
      await e.copy(dest);
    }
  }
}
