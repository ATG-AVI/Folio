import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/document.dart';
import 'package:folio/library.dart';
import 'package:folio/main.dart' show wipeTemp;
import 'package:folio/native.dart';

/// A 1×1 PNG: the smallest real image the engine will decode.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

/// A library whose writes always fail.
class _NoSave extends Library {
  _NoSave(super.root);

  @override
  Future<void> save(Document d) => Future.error(const FileSystemException('disk error'));
}

/// A library whose disk fills up: [room] more copies succeed, then every copy fails with ENOSPC.
class _FullDisk extends Library {
  _FullDisk(super.root);

  int room = 1 << 30;

  @override
  Future<DocPage> addImage(Document doc, String path) =>
      room-- > 0 ? super.addImage(doc, path) : Future.error(FileSystemException('write', path, OSError('No space left on device', 28)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('folio/native');

  /// Stands in for the native side of the channel until the test ends.
  void native(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('folio_lib'));
  // Best effort: a background render may still be finishing in this folder.
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // The OS clears its temp folder; a stray file here doesn't matter.
    }
  });

  String root() => '${tmp.path}/library';
  var n = 0;
  String image() => (File('${tmp.path}/in${n++}.png')..writeAsBytesSync(_png)).path;

  /// A saved two-page document, with its renders finished and written.
  Future<Document> scanned(Library library, {String name = 'Lease'}) async {
    final d = (await ingest(library, [image(), image()], name: name)).doc!;
    await library.renderIdle();
    await library.flush();
    return library.byId(d.id)!;
  }

  /// Every queued render and write has finished.
  Future<void> settle(Library library) async {
    await library.renderIdle();
    await library.flush();
  }

  test('documents and every edit survive a restart', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    const corners = [0.1, 0.1, 0.9, 0.1, 0.9, 0.9, 0.1, 0.9];
    await library.save(
      d
          .copyWith(name: 'Lease agreement', pageSize: PageSize.a4, quality: Quality.high)
          .updatePage(1, d.pages[1].copyWith(turns: 1, filter: PageFilter.bw, corners: corners))
          .movePage(1, 0),
    );

    await settle(library);
    final reopened = (await Library.open(root())).byId(d.id)!;
    expect(reopened.name, 'Lease agreement');
    expect(reopened.pageSize, PageSize.a4);
    expect(reopened.quality, Quality.high);
    expect(reopened.pages.map((p) => p.id), [d.pages[1].id, d.pages[0].id]);
    expect(reopened.pages.first.filter, PageFilter.bw);
    expect(reopened.pages.first.turns, 1);
    expect(reopened.pages.first.corners, corners);
    for (final p in reopened.pages) {
      expect(File(reopened.pathOf(p)).existsSync(), isTrue);
      expect((p.w, p.h), (1, 1));
    }
  });

  test('manifest round-trips and ignores fields from newer versions', () {
    final d = Document(
      id: 'abc',
      dir: '/x/abc',
      name: 'Bill',
      kind: DocKind.idCard,
      createdAt: DateTime(2026, 10, 1, 9, 30),
      updatedAt: DateTime(2026, 10, 2, 10),
      pages: const [
        DocPage(id: 'p', src: 'src/s.jpg', w: 10, h: 20, r: 'h1', corners: [0, 0, 1, 0, 1, 1, 0, 1], turns: 3),
      ],
    );
    final json = jsonDecode(jsonEncode(d.toJson())) as Map<String, Object?>;
    json['addedLater'] = true;
    ((json['pages']! as List).first as Map)['ocr'] = 'text';
    expect(Document.fromJson(json, id: 'abc', dir: '/x/abc').toJson(), d.toJson());
  });

  test('searchable is an optional doc.json field: unwritten when off, version still 1, old manifests load as off', () async {
    final d = Document(id: 'abc', dir: '/x/abc', name: 'Bill', createdAt: DateTime(2026), updatedAt: DateTime(2026), pages: const []);
    expect(d.searchable, isFalse);
    expect(d.toJson().containsKey('searchable'), isFalse);

    final on = d.copyWith(searchable: true);
    final json = jsonDecode(jsonEncode(on.toJson())) as Map<String, Object?>;
    expect([json['v'], json['searchable']], [1, true]);
    expect(Document.fromJson(json, id: 'abc', dir: '/x/abc').searchable, isTrue);
    expect(on.copyWith(name: 'Other').searchable, isTrue, reason: 'other edits keep it');
    expect(on.copyWith(searchable: false).toJson().containsKey('searchable'), isFalse);

    expect(
      Document.fromJson({...json}..remove('searchable'), id: 'abc', dir: '/x/abc').searchable,
      isFalse,
      reason: 'an old manifest',
    );
    expect(
      Document.fromJson({...json, 'searchable': 'yes'}, id: 'abc', dir: '/x/abc').searchable,
      isFalse,
      reason: 'only true counts',
    );
  });

  test('searchable survives a restart and a duplicate', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    await library.save(d.copyWith(searchable: true));
    await settle(library);
    final reopened = await Library.open(root());
    expect(reopened.byId(d.id)!.searchable, isTrue);
    await reopened.duplicate(reopened.byId(d.id)!);
    expect(reopened.query('', DocSort.recent).map((x) => x.searchable), [true, true]);
  });

  test('a manifest cannot point outside its document folder', () {
    for (final (src, r) in [('../../other/doc.json', null), ('/etc/passwd', null), ('cache/x.jpg', null), ('src/a.jpg', '../../../x')]) {
      expect(() => DocPage.fromJson({'id': 'a', 'src': src, 'r': r, 'w': 1, 'h': 1}), throwsFormatException, reason: '$src $r');
    }
  });

  test('a manifest from a newer app version loads as damaged, untouched', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    final file = File('${d.dir}/doc.json');
    final newer = (jsonDecode(file.readAsStringSync()) as Map<String, Object?>)..['v'] = 2;
    file.writeAsStringSync(jsonEncode(newer));
    final reopened = await Library.open(root());
    expect(reopened.byId(d.id)!.damaged, isTrue);
    expect(Directory('${d.dir}/src').listSync(), hasLength(2), reason: 'not swept');
    expect(file.readAsStringSync(), jsonEncode(newer));
  });

  test('loading sweeps interrupted writes and orphans but keeps every referenced file', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    Directory('${root()}/half-duplicate.tmp/src').createSync(recursive: true);
    File('${d.dir}/doc.json.tmp').writeAsStringSync('{"half');
    File('${d.dir}/src/replaced.jpg').writeAsBytesSync(_png);
    Directory('${d.dir}/cache').createSync();
    File('${d.dir}/cache/stale-1.jpg').writeAsBytesSync(_png);

    final reopened = (await Library.open(root())).byId(d.id)!;
    expect(Directory('${root()}/half-duplicate.tmp').existsSync(), isFalse);
    expect(File('${d.dir}/doc.json.tmp').existsSync(), isFalse);
    expect(File('${d.dir}/src/replaced.jpg').existsSync(), isFalse);
    expect(File('${d.dir}/cache/stale-1.jpg').existsSync(), isFalse);
    expect(reopened.pages.map((p) => File(reopened.pathOf(p)).existsSync()), everyElement(isTrue));
  });

  test('an unreadable manifest shows as damaged and is only deleted on request', () async {
    Directory('${root()}/broken').createSync(recursive: true);
    File('${root()}/broken/doc.json').writeAsStringSync('{"name": "Tax return", "pages": [');

    final library = await Library.open(root());
    expect(library.byId('broken')!.damaged, isTrue);
    expect(File('${root()}/broken/doc.json').existsSync(), isTrue);

    await library.save(library.byId('broken')!.copyWith(name: 'Renamed'));
    expect(File('${root()}/broken/doc.json').readAsStringSync(), contains('"pages": ['), reason: 'never overwritten');

    await library.delete('broken');
    expect(Directory('${root()}/broken').existsSync(), isFalse);
  });

  test('duplicate is an independent copy; delete removes the folder', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    await library.duplicate(d);
    final copy = library.query('copy', DocSort.recent).single;
    expect(copy.name, 'Lease copy');
    expect(copy.dir, isNot(d.dir));

    await library.delete(d.id);
    expect(Directory(d.dir).existsSync(), isFalse);
    final reopened = (await Library.open(root())).byId(copy.id)!;
    expect(reopened.pages, hasLength(2));
    expect(reopened.pages.map((p) => File(reopened.pathOf(p)).existsSync()), everyElement(isTrue));
  });

  test('rapid saves land in order', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    for (var i = 0; i < 20; i++) {
      library.save(library.byId(d.id)!.copyWith(name: 'v$i'));
    }
    await settle(library);
    expect((await Library.open(root())).byId(d.id)!.name, 'v19');
  });

  test('a failed write fails its own future, is reported once, and the queue carries on', () async {
    final errors = <Object>[];
    final library = Library('/dev/null/library', onError: errors.add);
    final d = library.newDocument().copyWith(
      pages: const [DocPage(id: 'a', src: 'src/a.jpg', w: 1, h: 1)],
    );
    await expectLater(library.save(d), throwsA(isA<FileSystemException>()));
    library.save(d); // fire-and-forget, as the UI does: must not become an unhandled error
    await library.flush();
    expect(errors, hasLength(2));
    expect(library.byId(d.id), isNotNull);
  });

  test('a crash after copying pages in but before the first save loses nothing', () async {
    final inbox = Directory('${tmp.path}/inbox')..createSync();
    final scan = (File('${inbox.path}/page1.jpg')..writeAsBytesSync(_png)).path;
    final library = await Library.open(root());
    await library.addImage(library.newDocument(), scan); // ...and the app is killed here

    final relaunched = await Library.open(root());
    expect(relaunched.isEmpty, isTrue, reason: 'the unsaved folder is cleared, not shown as damaged');
    expect(Directory(root()).listSync(), isEmpty);
    await recoverInbox(relaunched, inbox.path);
    expect(relaunched.query('', DocSort.recent).single.pages, hasLength(1));
    expect(File(scan).existsSync(), isFalse, reason: 'deleted only once the manifest was saved');
  });

  test('if the save fails, ingest throws and keeps its inputs', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    Directory('${d.dir}/doc.json.tmp').createSync(); // makes the next manifest write fail
    final input = image();
    await expectLater(ingest(library, [input], into: d), throwsA(anything));
    expect(File(input).existsSync(), isTrue);
  });

  test('a full disk mid-ingest frees the copies already made and keeps every input', () async {
    final library = _FullDisk(root());
    final d = await scanned(library);
    final into = [image(), image(), image()];
    library.room = 1;
    await expectLater(ingest(library, into, into: d), throwsA(predicate(storageFull)));
    expect(Directory('${d.dir}/src').listSync(), hasLength(2), reason: 'only the saved pages remain');

    final fresh = [image(), image(), image()];
    library.room = 1;
    await expectLater(ingest(library, fresh), throwsA(predicate(storageFull)));
    expect(Directory(root()).listSync().map((e) => e.path), [d.dir], reason: 'the new document\'s folder is gone');
    expect([...into, ...fresh].every((p) => File(p).existsSync()), isTrue);
  });

  test('ingest into a document deleted meanwhile adds nothing and keeps its inputs', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    final input = image();
    final pending = ingest(library, [input], into: d);
    await library.delete(d.id);
    expect((await pending).doc, isNull);
    expect(File(input).existsSync(), isTrue);
    expect((await Library.open(root())).byId(d.id), isNull);
  });

  test('ingest skips files that are not images and leaves them where they were', () async {
    final library = await Library.open(root());
    final good = image();
    final bad = File('${tmp.path}/notes.txt')..writeAsStringSync('not an image');
    final r = await ingest(library, [good, bad.path]);
    expect(r.failed, 1);
    expect(r.doc!.pages, hasLength(1));
    expect(bad.existsSync(), isTrue);
    expect(File(good).existsSync(), isFalse, reason: 'moved into the document');
  });

  test('ingest into a document appends to its latest version', () async {
    final library = await Library.open(root());
    final d = await scanned(library);
    library.save(d.copyWith(name: 'Renamed meanwhile'));
    await ingest(library, [image()], into: d);
    final now = library.byId(d.id)!;
    expect(now.name, 'Renamed meanwhile');
    expect(now.pages, hasLength(3));
  });

  test('scans left in the inbox become a Recovered scan document', () async {
    final inbox = Directory('${tmp.path}/inbox')..createSync();
    for (final name in ['page1.jpg', 'page2.jpg']) {
      File('${inbox.path}/$name').writeAsBytesSync(_png);
    }
    final library = await Library.open(root());
    await recoverInbox(library, inbox.path);
    expect(library.query('Recovered scan', DocSort.recent).single.pages, hasLength(2));
    expect(inbox.listSync(), isEmpty);
  });

  /// An inbox holding [pages] scanner files, named as the native side names them.
  Directory inboxOf(int pages) {
    final inbox = Directory('${tmp.path}/inbox')..createSync();
    for (var i = 0; i < pages; i++) {
      File('${inbox.path}/scan-1-${'$i'.padLeft(3, '0')}.jpg').writeAsBytesSync(_png);
    }
    return inbox;
  }

  test('inboxReady from the platform recovers the inbox into one Recovered scan', () async {
    final inbox = inboxOf(2);
    final library = await Library.open(root());
    Native.onInboxReady(() => recoverInbox(library, inbox.path));
    addTearDown(() => channel.setMethodCallHandler(null));
    // What the Android side sends once a late scan result is in the inbox.
    Future<void> inboxReady() => messenger.handlePlatformMessage(
      'folio/native',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('inboxReady')),
      (_) {},
    );

    await inboxReady();
    expect(library.query('Recovered scan', DocSort.recent).single.pages, hasLength(2));
    expect(inbox.listSync(), isEmpty);
    await inboxReady();
    expect(library.query('', DocSort.recent), hasLength(1), reason: 'an empty inbox adds nothing');
  });

  test('overlapping recovery passes ingest each file once', () async {
    final inbox = inboxOf(3);
    final library = await Library.open(root());
    await Future.wait([recoverInbox(library, inbox.path), recoverInbox(library, inbox.path)]);
    expect(library.query('', DocSort.recent).single.pages, hasLength(3));
  });

  test('a failed recovery pass reports to its caller and does not stop the next one', () async {
    final inbox = inboxOf(1);
    await expectLater(recoverInbox(_NoSave(root()), inbox.path), throwsA(isA<FileSystemException>()));
    expect(inbox.listSync(), hasLength(1), reason: 'kept for the next pass');
    final library = await Library.open(root());
    await recoverInbox(library, inbox.path);
    expect(library.query('Recovered scan', DocSort.recent).single.pages, hasLength(1));
  });

  test('scan returns the inbox paths, and none when cancelled', () async {
    native((c) async => c.arguments['pageLimit'] == 1 ? ['/inbox/a.jpg'] : ['/inbox/a.jpg', '/inbox/b.jpg']);
    expect(await Native.scan(pageLimit: 1), ['/inbox/a.jpg']);
    expect(await Native.scan(), ['/inbox/a.jpg', '/inbox/b.jpg']);
    native((_) async => null);
    expect(await Native.scan(), isEmpty);
  });

  test('scan maps native errors to ScanError, and a missing native side to unavailable', () async {
    Matcher fails(ScanError e) => throwsA(isA<ScanException>().having((x) => x.error, 'error', e));
    for (final (code, error) in [
      ('unavailable', ScanError.unavailable),
      ('denied', ScanError.denied),
      ('failed', ScanError.failed),
      ('anything else', ScanError.failed),
    ]) {
      native((_) async => throw PlatformException(code: code));
      await expectLater(Native.scan(), fails(error), reason: code);
    }
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(Native.scan(), fails(ScanError.unavailable));
  });

  test('detectCorners returns the eight values, or null when there are none or detection fails', () async {
    const corners = [0.1, 0.1, 0.9, 0.12, 0.88, 0.9, 0.12, 0.88];
    native((c) async => c.arguments['path'] == '/p.jpg' ? corners : null);
    expect(await Native.detectCorners('/p.jpg'), corners);
    expect(await Native.detectCorners('/other.jpg'), isNull, reason: 'Android answers null');
    native((_) async => throw PlatformException(code: 'failed'));
    expect(await Native.detectCorners('/p.jpg'), isNull);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await Native.detectCorners('/p.jpg'), isNull, reason: 'no native side');
  });

  test('ingest presets detected corners before its one save', () async {
    const corners = [0.1, 0.1, 0.9, 0.12, 0.88, 0.9, 0.12, 0.88];
    native((c) async => c.method == 'detectCorners' ? corners : null);
    final library = await Library.open(root());
    final d = (await ingest(library, [image()], corners: true)).doc!;
    expect(d.pages.single.corners, corners);
  });

  test('a full disk is told apart from a bad file', () {
    expect(storageFull(const FileSystemException('write', '/x', OSError('No space left on device', 28))), isTrue);
    expect(storageFull(const FileSystemException('write', '/x', OSError('Permission denied', 13))), isFalse);
    expect(storageFull(const FormatException('Not an image')), isFalse);
  });

  test('picker leftovers from earlier sessions are cleared, nothing else', () async {
    final cache = Directory('${tmp.path}/cache')..createSync();
    final old = DateTime.now().subtract(const Duration(hours: 1));
    File make(String name) => File('${cache.path}/$name')..writeAsStringSync('x');
    final uuidDir = Directory('${cache.path}/0f8fad5b-d9cb-469f-a165-70867728950e')..createSync();
    File('${uuidDir.path}/IMG_1.jpg').writeAsStringSync('x');
    final scaled = make('scaled_IMG_2.jpg')..setLastModifiedSync(old);
    final camera = make('7c9e6679-7425-40de-944b-e07fc1f90ae7123.jpg')..setLastModifiedSync(old);
    final fresh = make('scaled_IMG_3.jpg'); // written after launch: a lost-pick handoff in progress
    final other = make('mlkit_scan.jpg')..setLastModifiedSync(old);
    // Directory mtimes can't be set from Dart; launch after creation makes the folder count as old.
    await clearPickerCopies(cache.path, android: true, launch: DateTime.now().add(const Duration(seconds: 1)));
    expect([uuidDir.existsSync(), scaled.existsSync(), camera.existsSync(), other.existsSync()], [false, false, false, true]);
    fresh.writeAsStringSync('x');
    await clearPickerCopies(cache.path, android: true, launch: DateTime.now().subtract(const Duration(minutes: 1)));
    expect(fresh.existsSync(), isTrue, reason: 'newer than launch: kept');

    final ios = Directory('${tmp.path}/tmp')..createSync();
    final pick = File('${ios.path}/image_picker_ABC123.jpg')..writeAsStringSync('x');
    final keep = File('${ios.path}/share.pdf')..writeAsStringSync('x');
    await clearPickerCopies(ios.path, android: false, launch: DateTime.now());
    expect([pick.existsSync(), keep.existsSync()], [false, true]);
  });

  test('wipeTemp clears our temp folder and printing’s share copies, nothing else', () async {
    File('${tmp.path}/folio/export.pdf')
      ..createSync(recursive: true)
      ..writeAsStringSync('pdf');
    File('${tmp.path}/share/Lease.pdf') // Android: printing's share copy, in the cache
      ..createSync(recursive: true)
      ..writeAsStringSync('pdf');
    final other = File('${tmp.path}/someone-else')..writeAsStringSync('keep');
    // iOS: printing shares from tmp/, which also holds other plugins' files.
    final iosTmp = Directory('${tmp.path}/ios-tmp')..createSync();
    final sharedPdf = File('${iosTmp.path}/Lease.pdf')..writeAsStringSync('pdf');
    final pick = File('${iosTmp.path}/image_picker_1.jpg')..writeAsStringSync('jpg');

    await wipeTemp(tmp.path);
    expect(Directory('${tmp.path}/folio').existsSync(), isFalse);
    expect(Directory('${tmp.path}/share').existsSync(), isFalse);
    expect([other.existsSync(), sharedPdf.existsSync()], [true, true], reason: 'iOS tmp/ is only touched when asked');

    await wipeTemp(tmp.path, iosTmp: iosTmp.path);
    expect([sharedPdf.existsSync(), pick.existsSync(), other.existsSync()], [false, true, true]);
    await wipeTemp('${tmp.path}/none', iosTmp: '${tmp.path}/none'); // nothing there yet: no error
  });
}
