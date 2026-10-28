import 'dart:math';
import 'dart:ui' show Size;

import 'render.dart';

export 'render.dart' show PageFilter;

enum DocKind { document, idCard }

enum PageSize { fit, a4, letter }

enum Quality { small, standard, high }

final _rng = Random.secure();

/// 16 hex chars, enough to never collide on one phone.
String newId() => List.generate(8, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

class DocPage {
  const DocPage({
    required this.id,
    required this.src,
    required this.w,
    required this.h,
    this.r,
    this.corners,
    this.turns = 0,
    this.filter = PageFilter.original,
  });

  final String id;

  /// Original image, relative to the document folder.
  final String src;

  /// Rendered output: a hash of src + edit params (so equal pages share one render). Null until rendered.
  final String? r;

  /// Pixel size of the image shown for this page (render if present, else src).
  final int w, h;

  /// TL, TR, BR, BL as x,y pairs normalised to 0..1, in upright src space. Null = full image.
  final List<double>? corners;
  final int turns;
  final PageFilter filter;

  /// Size as shown. A render has crop and rotation baked in; a bare src is rotated on the fly.
  Size get size => r == null && turns.isOdd ? Size(h.toDouble(), w.toDouble()) : Size(w.toDouble(), h.toDouble());

  double get aspect => size.aspectRatio;

  String? get renderPath => r == null ? null : 'cache/$r.jpg';

  Map<String, Object?> toJson() => {
    'id': id,
    'src': src,
    'w': w,
    'h': h,
    if (r != null) 'r': r,
    if (corners != null) 'corners': corners,
    'turns': turns,
    'filter': filter.name,
  };

  factory DocPage.fromJson(Map<String, Object?> j) {
    final src = j['src']! as String, r = j['r'] as String?;
    // File names only: a manifest can never point outside its own folder.
    if (!RegExp(r'^src/\w+\.jpg$').hasMatch(src) || (r != null && !RegExp(r'^\w+$').hasMatch(r))) {
      throw FormatException('Bad page path: $src $r');
    }
    return DocPage(
      id: j['id']! as String,
      src: src,
      w: j['w']! as int,
      h: j['h']! as int,
      r: r,
      corners: (j['corners'] as List?)?.map((e) => (e as num).toDouble()).toList(growable: false),
      turns: (j['turns'] as int? ?? 0) % 4,
      filter: PageFilter.values.asNameMap()[j['filter']] ?? PageFilter.original,
    );
  }

  DocPage copyWith({String? id, String? src, String? r, int? w, int? h, List<double>? corners, int? turns, PageFilter? filter}) => DocPage(
    id: id ?? this.id,
    src: src ?? this.src,
    r: r ?? this.r,
    w: w ?? this.w,
    h: h ?? this.h,
    corners: corners ?? this.corners,
    turns: turns ?? this.turns,
    filter: filter ?? this.filter,
  );
}

class Document {
  const Document({
    required this.id,
    required this.dir,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
    this.kind = DocKind.document,
    this.pageSize = PageSize.fit,
    this.quality = Quality.standard,
    this.searchable = false,
    this.damaged = false,
  });

  final String id;

  /// Absolute folder; page paths are relative to it.
  final String dir;
  final String name;
  final DocKind kind;
  final DateTime createdAt, updatedAt;
  final PageSize pageSize;
  final Quality quality;

  /// Export with an invisible text layer (PRD O3). Optional in doc.json: written only when on.
  final bool searchable;
  final List<DocPage> pages;

  /// doc.json could not be read. Shown as "Can't open"; never deleted automatically.
  final bool damaged;

  String pathOf(DocPage p) => '$dir/${p.renderPath ?? p.src}';

  /// Long edge and JPEG quality of this document's renders (plan §7.4). ID-card sides are small on
  /// the page, so 1100 px is already about 300 dpi at 85.6 mm.
  (int maxEdge, int quality) get renderPreset => (
    kind == DocKind.idCard
        ? 1100
        : switch (quality) {
            Quality.small => 1600,
            Quality.standard => 2200,
            Quality.high => 3000,
          },
    switch (quality) {
      Quality.small => 60,
      Quality.standard => 75,
      Quality.high => 85,
    },
  );

  /// The render name this page should have now. Anything that changes the output must be in here;
  /// bump the leading version when the render code itself changes output.
  String renderKey(DocPage p) {
    final (edge, q) = renderPreset;
    return stableHash('r1|${p.src}|${p.corners?.map((c) => c.toStringAsFixed(4)).join(',')}|${p.turns}|${p.filter.name}|$edge|$q');
  }

  bool isRendered(DocPage p) => p.r == renderKey(p);

  /// doc.json, version 1. [dir] and [damaged] are runtime-only.
  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'name': name,
    'kind': kind.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'pageSize': pageSize.name,
    'quality': quality.name,
    if (searchable) 'searchable': true,
    'pages': [for (final p in pages) p.toJson()],
  };

  /// Throws on anything malformed or from a newer format (a newer app's fields must not be dropped
  /// by re-saving here). Unknown enum values fall back to defaults.
  factory Document.fromJson(Map<String, Object?> j, {required String id, required String dir}) {
    if (j['v'] != 1) throw FormatException('Unsupported manifest version ${j['v']}');
    return Document(
      id: id,
      dir: dir,
      name: j['name']! as String,
      kind: DocKind.values.asNameMap()[j['kind']] ?? DocKind.document,
      createdAt: DateTime.parse(j['createdAt']! as String).toLocal(),
      updatedAt: DateTime.parse(j['updatedAt']! as String).toLocal(),
      pageSize: PageSize.values.asNameMap()[j['pageSize']] ?? PageSize.fit,
      quality: Quality.values.asNameMap()[j['quality']] ?? Quality.standard,
      searchable: j['searchable'] == true,
      pages: [for (final p in j['pages']! as List) DocPage.fromJson(p as Map<String, Object?>)],
    );
  }

  Document copyWith({
    String? id,
    String? dir,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    PageSize? pageSize,
    Quality? quality,
    bool? searchable,
    List<DocPage>? pages,
  }) => Document(
    id: id ?? this.id,
    dir: dir ?? this.dir,
    name: name ?? this.name,
    kind: kind,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pageSize: pageSize ?? this.pageSize,
    quality: quality ?? this.quality,
    searchable: searchable ?? this.searchable,
    pages: pages ?? this.pages,
    damaged: damaged,
  );

  // Pure page ops. Screens call these, then Library.save().

  /// [to] is the final index, as ReorderableListView.onReorderItem reports it.
  Document movePage(int from, int to) {
    final l = [...pages];
    l.insert(to, l.removeAt(from));
    return copyWith(pages: l);
  }

  Document duplicatePage(int i) => copyWith(pages: [...pages]..insert(i + 1, pages[i].copyWith(id: newId())));

  Document removePage(int i) => copyWith(pages: [...pages]..removeAt(i));

  Document updatePage(int i, DocPage p) => copyWith(pages: [...pages]..[i] = p);
}
