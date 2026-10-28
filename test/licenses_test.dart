import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/licenses.dart';

String text(LicenseEntry e) => e.paragraphs.map((p) => p.text).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Drops Flutter's own collector: it reads the NOTICES file that only a built app has.
  setUp(LicenseRegistry.reset);

  test('Android lists image’s and Roboto’s notices and every ML Kit library, each with its own text', () async {
    registerLicenses(android: true);
    final entries = {for (final e in await LicenseRegistry.licenses.toList()) e.packages.single: text(e)};

    expect(entries['image'], contains('notmasteryet'), reason: 'LICENSE-other.md');
    expect(entries['Roboto (PDF text font)'], contains('Apache License'), reason: 'assets/fonts/Roboto_LICENSE.txt');
    expect(entries, hasLength(68), reason: 'image + Roboto + the 66 libraries in the ML Kit index');
    // Offsets are bytes, and the entries tile the text: the first, a middle and the last one start and end right.
    expect(entries['Android SDK Platforms'], startsWith('ANDROID SOFTWARE DEVELOPMENT KIT'));
    expect(entries['Kotlin'], startsWith('Files: kotlinc/*'));
    expect(entries['Animal Sniffer'], startsWith('The MIT License'));
    expect(entries['kotlinx_serialization']!.trimRight(), endsWith('limitations under the License.'));
    expect(entries.values.every((t) => t.trim().isNotEmpty), isTrue);
  });

  test('iOS lists only image’s and Roboto’s notices and never touches the ML Kit assets', () async {
    registerLicenses(android: false);
    expect([for (final e in await LicenseRegistry.licenses.toList()) e.packages.single], ['image', 'Roboto (PDF text font)']);
  });
}
