import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Notices that Flutter's licence page (one LICENSE per package) doesn't already show: `image`'s bundled third-party
/// code, the Roboto font embedded in searchable PDFs, and, on Android, ML Kit's dependencies. Read only when the page opens.
void registerLicenses({bool? android}) {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['image'], await rootBundle.loadString('assets/licenses/image_LICENSE-other.md'));
    yield LicenseEntryWithLineBreaks(['Roboto (PDF text font)'], await rootBundle.loadString('assets/fonts/Roboto_LICENSE.txt'));
    if (android ?? Platform.isAndroid) {
      Future<Uint8List> gz(String name) async =>
          (await rootBundle.load('assets/licenses/mlkit_third_party_licenses.$name.gz')).buffer.asUint8List();
      yield* Stream.fromIterable(mlKitNotices(await gz('json'), await gz('txt')));
    }
  });
}

/// One entry per library from ML Kit's `third_party_licenses.{json,txt}` (copied from the
/// play-services-mlkit-document-scanner AAR, gzipped; refresh them when that dependency's version changes).
/// The JSON maps each name to `{start, length}`, UTF-8 byte offsets into the text.
List<LicenseEntry> mlKitNotices(List<int> indexGz, List<int> textGz) {
  final index = jsonDecode(utf8.decode(gzip.decode(indexGz))) as Map<String, dynamic>;
  final text = gzip.decode(textGz);
  return [
    for (final MapEntry(key: name, value: at) in index.entries)
      LicenseEntryWithLineBreaks([name], utf8.decode(text.sublist(at['start'] as int, (at['start'] as int) + (at['length'] as int)))),
  ];
}
