import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A /FlateDecode stream's bytes (given one character per byte) inflated, again one character per byte.
String inflate(String raw) => latin1.decode(zlib.decode(latin1.encode(raw)));

/// [pdf] as text, one character per byte, with every /FlateDecode stream inflated in place (the dictionary and the
/// framing stay as they are, /Length included). A searchable PDF deflates its content, font and ToUnicode streams, so
/// tests that read them go through this; a PDF without a text layer comes back unchanged.
String inflated(Uint8List pdf) {
  final s = latin1.decode(pdf), out = StringBuffer();
  var at = 0;
  for (final m in RegExp(r'/Filter/FlateDecode/Length (\d+)>>stream\n').allMatches(s)) {
    if (m.start < at) continue; // inside a stream already taken
    final end = m.end + int.parse(m[1]!);
    out
      ..write(s.substring(at, m.end))
      ..write(inflate(s.substring(m.end, end)));
    at = end;
  }
  return (out..write(s.substring(at))).toString();
}
