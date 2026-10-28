import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart' as app;
import 'package:folio/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On a real device/simulator: real app directories, edits made through the UI, then a reload from disk.
/// Run: fvm flutter test integration_test/persistence_test.dart -d DEVICE
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edits made in the app survive reloading the library from disk', (tester) async {
    final support = (await getApplicationSupportDirectory()).path;
    final root = '$support/persistence_test';
    if (Directory(root).existsSync()) Directory(root).deleteSync(recursive: true);
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');
    final inbox = Directory('$support/persistence_inbox')..createSync(recursive: true);
    for (final n in ['1.jpg', '2.jpg', '3.jpg']) {
      File('${inbox.path}/$n').writeAsBytesSync(png);
    }

    final library = await Library.open(root);
    await recoverInbox(library, inbox.path);
    final id = library.query('', DocSort.recent).single.id;
    await tester.pumpWidget(FolioApp(library: library));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Recovered scan'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Signed lease');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Page options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await library.flush();

    final reloaded = (await Library.open(root)).byId(id)!;
    expect(reloaded.name, 'Signed lease');
    expect(reloaded.pages, hasLength(2));
    expect(reloaded.pages.map((p) => File(reloaded.pathOf(p)).existsSync()), everyElement(isTrue));
    expect(inbox.listSync(), isEmpty);

    Directory(root).deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  testWidgets('cold start runs the real startup sequence', (tester) async {
    final temp = (await getTemporaryDirectory()).path;
    File('$temp/folio/stale-export.pdf')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('Documents'), findsWidgets); // large app bar renders the title twice
    expect(Directory('$temp/folio').existsSync(), isFalse);
  });
}
