import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'native.dart';

/// One recognised line of a page's render. [box] is normalised 0..1 with a top-left origin in the image.
class OcrLine {
  const OcrLine(this.text, this.box);

  final String text;
  final Rect box;

  /// The channel's `{'text': String, 'box': [left, top, right, bottom]}`. Throws on anything else.
  factory OcrLine.fromMap(Map<dynamic, dynamic> m) {
    final [l, t, r, b] = [for (final v in m['box'] as List) (v as num).toDouble()];
    return OcrLine(m['text'] as String, Rect.fromLTRB(l, t, r, b));
  }
}

// Keyed by render file path, which embeds the render key: an edited page has a new path. Holds recognised text
// (never logged or written anywhere) until the app closes.
// Limit: unbounded; a page is a few KB, so it takes thousands of pages to matter. Cap it if that ever changes.
final _cache = <String, List<OcrLine>>{};

// Reads in flight, so a double tap or a cancel and retry doesn't send the same page to native twice.
final _reading = <String, Future<List<OcrLine>?>>{};

@visibleForTesting
void clearTextCache() {
  _cache.clear();
  _reading.clear();
}

/// The lines of the render at [path] in reading order, read once per session. Null = no recogniser or it failed, and
/// that is never remembered, so a later try (the model finished downloading) can succeed. [] = read, no text found.
Future<List<OcrLine>?> readText(String path) {
  final cached = _cache[path];
  if (cached != null) return Future.value(cached);
  // A block body: an arrow would return the removed future itself, which whenComplete would then wait for.
  return _reading[path] ??= _read(path).whenComplete(() {
    _reading.remove(path);
  });
}

Future<List<OcrLine>?> _read(String path) async {
  final lines = await Native.recognizeText(path);
  return lines == null ? null : _cache[path] = _inRows(lines);
}

/// Rows top to bottom, each left to right. Native sorts by top alone, so on a receipt an amount a hair higher than its
/// label would come out first. A line is on the current row while its top is above the row's first line's centre.
List<OcrLine> _inRows(List<OcrLine> lines) {
  final out = <OcrLine>[], row = <OcrLine>[];
  void flush() {
    out.addAll(row..sort((a, b) => a.box.left.compareTo(b.box.left)));
    row.clear();
  }

  for (final l in [...lines]..sort((a, b) => a.box.top.compareTo(b.box.top))) {
    if (row.isNotEmpty && l.box.top >= row.first.box.center.dy) flush();
    row.add(l);
  }
  flush();
  return out;
}
