import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'document.dart';
import 'library.dart';
import 'native.dart';
import 'page_screen.dart';
import 'pages_screen.dart';
import 'render.dart' show isConvex;
import 'ui.dart';

/// Where new pages come from. [scan] falls back to the user's choice of the others when the scanner
/// can't run.
enum Source { scan, photos, camera }

/// Captured files; where they really came from (a scan that fell back reports photos or camera); and
/// picks that were dropped before ingest (see [_pick]), so they can be reported with the other failures.
typedef Captured = ({List<String> paths, Source source, int skipped});

extension on Captured {
  /// The OS scanner produced them: already cropped and cleaned up.
  bool get scanned => source == Source.scan;
}

/// True while a scanner or picker is open. The one duplicate-capture guard for every entry point.
final scanning = ValueNotifier(false);

final _picker = ImagePicker();

/// Android: the picker-leftover sweep, set at launch and run before the session's first pick. Not
/// at launch itself: a camera photo from a pick the OS cut short is only handed back a moment later,
/// and the sweep would delete it. Once recovery has run, the next pick clears the plugin's store anyway.
({String dir, DateTime launch})? androidPickerSweep;

/// Gets pages from [source]. Explains scanner problems in a sheet; when the scanner is unavailable
/// the sheet's Import photos / Take photo choice is used instead. Empty when cancelled or busy.
Future<Captured> capturePages(BuildContext context, Source source, {int? pageLimit}) async {
  const none = (paths: <String>[], source: Source.photos, skipped: 0);
  if (scanning.value) return none;
  scanning.value = true;
  try {
    if (source == Source.scan) {
      try {
        return (paths: await Native.scan(pageLimit: pageLimit), source: Source.scan, skipped: 0);
      } on ScanException catch (e) {
        if (!context.mounted) return none;
        final fallback = await showScanProblem(context, e.error);
        if (fallback == null || !context.mounted) return none;
        source = fallback;
      }
    }
    if (!context.mounted) return none;
    return await _pick(context, source, single: pageLimit == 1);
  } finally {
    scanning.value = false;
  }
}

Future<Captured> _pick(BuildContext context, Source source, {required bool single}) async {
  const none = (paths: <String>[], source: Source.photos, skipped: 0);
  // 4000 px bounds memory for 48 MP photos; quality 90 decodes ~25% faster than 95 (plan §7.1, §11).
  const edge = 4000.0, quality = 90;
  // Android may still be holding photos from a pick cut short when the app was killed. Take them
  // now: the next pick would clear them (plan §5, startup step 2).
  if (Platform.isAndroid) {
    await recoverLostPicks(LibraryScope.of(context)).catchError((Object _) {});
    final sweep = androidPickerSweep;
    androidPickerSweep = null;
    if (sweep != null) await clearPickerCopies(sweep.dir, android: true, launch: sweep.launch).catchError((Object _) {});
  }
  if (!context.mounted) return none;
  try {
    if (source == Source.camera || single) {
      final from = source == Source.camera ? ImageSource.camera : ImageSource.gallery;
      final f = await _picker.pickImage(source: from, maxWidth: edge, maxHeight: edge, imageQuality: quality, requestFullMetadata: false);
      return (paths: [?f?.path], source: source, skipped: 0);
    }
    final files = await _picker.pickMultiImage(maxWidth: edge, maxHeight: edge, imageQuality: quality, requestFullMetadata: false);
    // Android names resized copies after the original file name, so two photos both called image.jpg
    // come back as one path holding only the second. Import it once; report the other as not added.
    final paths = {for (final f in files) f.path}.toList();
    return (paths: paths, source: source, skipped: files.length - paths.length);
  } on PlatformException catch (e) {
    if (!context.mounted) return none;
    switch (e.code) {
      case 'camera_access_denied' || 'camera_access_restricted':
        await showScanProblem(context, ScanError.denied);
      case 'no_available_camera':
        await alert(context, 'No camera available', 'This device has no camera Folio can use. Import photos instead.');
      default:
        await alert(
          context,
          'Couldn’t open that photo',
          'It may still be downloading from iCloud, or be in a format Folio can’t read. Try another photo.',
        );
    }
    return none;
  }
}

/// Adds scanned or imported pages to a new document, or to [intoId].
Future<void> addPages(BuildContext context, Source source, {String? intoId, int? pageLimit}) async {
  final got = await capturePages(context, source, pageLimit: pageLimit);
  if (got.paths.isNotEmpty && context.mounted) await addCaptured(context, got, intoId: intoId);
}

/// Ingests [got] into [intoId] or a new document of [kind], with a progress dialog (Cancel keeps the
/// pages already added), then opens the next step: imports go to Crop & Enhance, and a new document
/// lands on Review Pages (plan §4: Scan or Import → Crop & Enhance → Review Pages).
Future<void> addCaptured(BuildContext context, Captured got, {String? intoId, DocKind kind = DocKind.document}) async {
  final library = LibraryScope.of(context);
  final into = intoId == null ? null : library.byId(intoId);
  final before = into?.pages.length ?? 0, total = got.paths.length, done = ValueNotifier(0);
  var stop = false, saved = false;
  if (total > 1) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _Progress(total: total, done: done, onCancel: () => stop = true),
    );
  }
  late final ({Document? doc, int failed}) r;
  try {
    r = await ingest(
      library,
      got.paths,
      into: into,
      kind: kind,
      name: kind == DocKind.idCard ? defaultName(DateTime.now(), 'ID card') : null,
      filter: got.scanned ? PageFilter.original : PageFilter.enhance,
      corners: !got.scanned,
      onProgress: (n) => done.value = n,
      cancelled: () => stop,
    );
    saved = true;
  } catch (e) {
    if (context.mounted) toast(context, storageFull(e) ? _noSpace : 'Couldn’t add the pages. Try again.');
    return;
  } finally {
    if (total > 1 && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    // What ingest didn't take: picker copies always go; scanner files go once the save worked (pages
    // the user cancelled) but stay in the inbox to be recovered if it failed.
    if (saved || !got.scanned) _delete(got.paths);
  }
  final doc = r.doc;
  if (!context.mounted) return;
  final note = _failedNote(r.failed + got.skipped);
  if (stop && done.value < total) {
    toast(context, 'Stopped. ${(doc?.pages.length ?? before) - before} of $total added.');
  } else if (note != null && (doc == null || intoId != null)) {
    toast(context, note);
  }
  if (doc == null) return;
  if (intoId == null) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PagesScreen(docId: doc.id, notice: note),
      ),
    );
  }
  // The scanner already cropped and cleaned its pages; photos get a look first.
  if (!got.scanned) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PageScreen(docId: doc.id, initialIndex: before),
      ),
    );
  }
}

/// Retake (scanner) or replace from photos/camera, keeping the page's place and filter. Undo restores it.
Future<void> replacePage(BuildContext context, String docId, String pageId, Source source) async {
  final library = LibraryScope.of(context);
  final got = await capturePages(context, source, pageLimit: 1);
  final doc = library.byId(docId);
  try {
    if (got.paths.isEmpty || doc == null || !context.mounted) return;
    var page = await library.addImage(doc, got.paths.first);
    if (!got.scanned) page = await _withCorners(doc, page);
    final now = library.byId(docId);
    final i = now?.pages.indexWhere((p) => p.id == pageId) ?? -1;
    if (now == null || i < 0) return;
    final old = now.pages[i];
    await library.save(now.updatePage(i, page.copyWith(id: old.id, filter: got.scanned ? PageFilter.original : old.filter)));
    if (!context.mounted) return;
    toast(
      context,
      'Page replaced',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          final cur = library.byId(docId);
          final j = cur?.pages.indexWhere((p) => p.id == pageId) ?? -1;
          if (cur != null && j >= 0) library.save(cur.updatePage(j, old));
        },
      ),
    );
  } catch (e) {
    if (context.mounted) toast(context, storageFull(e) ? _noSpace : 'Couldn’t use that photo. Try another one.');
  } finally {
    _delete(got.paths); // copied into the document, or not wanted
  }
}

const _noSpace = 'Not enough free storage. Free up some space and try again.';

/// ENOSPC is 28 on Linux/Android and Darwin/iOS alike.
bool storageFull(Object e) => e is FileSystemException && e.osError?.errorCode == 28;

void _delete(List<String> paths) {
  for (final p in paths) {
    File(p).delete().ignore();
  }
}

String? _failedNote(int n) => n == 0 ? null : '$n ${n == 1 ? 'photo' : 'photos'} couldn’t be added. Try those again, or use other photos.';

/// Detected document corners for a photographed page (iOS Vision from M4; none on Android), else unchanged.
Future<DocPage> _withCorners(Document doc, DocPage p) async {
  final c = await Native.detectCorners('${doc.dir}/${p.src}');
  return c != null && c.length == 8 && isConvex(c) ? p.copyWith(corners: c) : p;
}

class _Progress extends StatelessWidget {
  const _Progress({required this.total, required this.done, required this.onCancel});

  final int total;
  final ValueNotifier<int> done;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: const Text('Adding photos'),
      content: ValueListenableBuilder(
        valueListenable: done,
        builder: (context, n, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${n < total ? n + 1 : total} of $total', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: n / total),
          ],
        ),
      ),
      actions: [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
    ),
  );
}

/// Adds image files to a document one at a time (bounded memory): copy in, save the manifest, and
/// only then delete the inputs, so a crash or failed write never loses a page (worst case it comes
/// back once more from the inbox). Files that aren't images are skipped and left in place.
/// Appends to the latest version of [into], or creates a new document. Returns null when nothing
/// was added or [into] was deleted meanwhile. Throws if the save fails; inputs are then kept.
/// [cancelled] is checked between files; pages added before it turned true are kept. [corners] presets
/// detected document corners on each page (for photos; scanner pages arrive cropped).
Future<({Document? doc, int failed})> ingest(
  Library library,
  List<String> paths, {
  Document? into,
  String? name,
  DocKind kind = DocKind.document,
  PageFilter filter = PageFilter.original,
  bool corners = false,
  void Function(int done)? onProgress,
  bool Function()? cancelled,
}) async {
  final target = into ?? library.newDocument(name: name, kind: kind);
  final pages = <DocPage>[], added = <String>[];
  var failed = 0;
  for (final (i, path) in paths.indexed) {
    if (cancelled?.call() ?? false) break;
    try {
      final page = (await library.addImage(target, path)).copyWith(filter: filter);
      // Corners before the save, so the first render already has the right crop.
      pages.add(corners ? await _withCorners(target, page) : page);
      added.add(path);
    } catch (e) {
      if (storageFull(e)) {
        // Not this file's fault: stop, keep the inputs. Free this call's copies first (no manifest
        // names them), or the disk stays full and the inbox recovery refills it on every launch.
        final List<FileSystemEntity> copies = into == null
            ? [Directory(target.dir)]
            : [for (final p in pages) File('${target.dir}/${p.src}')];
        for (final f in copies) {
          await f.delete(recursive: true).catchError((Object _) => f);
        }
        rethrow;
      }
      failed++; // not an image, or a decoder error on a damaged file: skip it, keep the file
    }
    onProgress?.call(i + 1);
  }
  final latest = into == null ? target : library.byId(into.id);
  if (pages.isEmpty || latest == null) return (doc: null, failed: failed);
  await library.save(latest.copyWith(pages: [...latest.pages, ...pages]));
  for (final path in added) {
    await File(path).delete().catchError((Object _) => File(path));
  }
  return (doc: library.byId(target.id), failed: failed);
}

Future<void> _recovering = Future.value();

/// Scanner pages land in the inbox first. Anything still there at launch arrived after the app was
/// killed mid-scan (plan §5, startup step 2), so it becomes a "Recovered scan" document. Passes run
/// one at a time: the startup pass and Android's `inboxReady` must not ingest the same files twice.
Future<void> recoverInbox(Library library, String inbox) {
  final pass = _recovering.then((_) => _recover(library, inbox));
  _recovering = pass.catchError((Object _) {}); // the caller sees a failure; the next pass still runs
  return pass;
}

Future<void> _recover(Library library, String inbox) async {
  final dir = Directory(inbox);
  if (!await dir.exists()) return;
  final files = [
    await for (final f in dir.list())
      if (f is File) f.path,
  ]..sort();
  if (files.isNotEmpty) await ingest(library, files, name: defaultName(DateTime.now(), 'Recovered scan'));
}

/// Android can kill the app while the picker or camera is open; those photos are handed back at launch.
Future<void> recoverLostPicks(Library library) async {
  final lost = await _picker.retrieveLostData();
  final paths = [for (final f in lost.files ?? const <XFile>[]) f.path];
  if (paths.isNotEmpty) {
    await ingest(library, paths, name: defaultName(DateTime.now(), 'Recovered photos'), filter: PageFilter.enhance);
  }
}

/// The photo picker never deletes its temporary copies (on Android, a full-size copy of every pick).
/// At launch, remove the ones from earlier sessions: Android's UUID-named and `scaled_*` entries in
/// the cache, older than [launch] (a lost-pick handoff may still be writing newer ones); iOS's
/// `image_picker_*` files in tmp/.
Future<void> clearPickerCopies(String dir, {required bool android, required DateTime launch}) async {
  final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}');
  if (!await Directory(dir).exists()) return;
  await for (final e in Directory(dir).list()) {
    final name = e.path.split('/').last;
    final ours = android ? name.startsWith('scaled_') || uuid.hasMatch(name) : name.startsWith('image_picker_');
    if (!ours || (android && !(await e.stat()).modified.isBefore(launch))) continue;
    await e.delete(recursive: true).catchError((Object _) => e);
  }
}

/// Explains a scanner problem. For [ScanError.unavailable] it returns the user's fallback choice.
Future<Source?> showScanProblem(BuildContext context, ScanError error) =>
    showModalBottomSheet<Source>(context: context, isScrollControlled: true, useSafeArea: true, builder: (context) => _ProblemSheet(error));

class _ProblemSheet extends StatelessWidget {
  const _ProblemSheet(this.error);

  final ScanError error;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body, primary, secondary) = switch (error) {
      ScanError.unavailable => (
        Icons.no_photography_outlined,
        'Scanner not available here',
        'This device can’t run the document scanner. You can still add pages from photos, or take a photo and crop it by hand.',
        'Import photos',
        'Take photo',
      ),
      ScanError.denied => (
        Icons.videocam_off_outlined,
        'Camera access is off',
        'Folio needs the camera to scan. Turn on camera access for Folio in Settings.',
        'Open Settings',
        'Not now',
      ),
      ScanError.failed => (
        Icons.error_outline,
        'The scan didn’t finish',
        'The scanner closed before saving any pages, so nothing was added. Try scanning again.',
        'Close',
        null,
      ),
    };
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final unavailable = error == ScanError.unavailable;
    return sheetBody(context, [
      Align(
        alignment: Alignment.centerLeft,
        child: CircleAvatar(
          radius: 26,
          backgroundColor: scheme.primaryContainer,
          child: Icon(icon, color: scheme.onPrimaryContainer),
        ),
      ),
      const SizedBox(height: 20),
      heading(title, text.headlineSmall),
      const SizedBox(height: 8),
      Text(body, style: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: 28),
      FilledButton(
        onPressed: () {
          if (error == ScanError.denied) Native.openSettings();
          Navigator.pop(context, unavailable ? Source.photos : null);
        },
        child: Text(primary),
      ),
      if (secondary != null) ...[
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.pop(context, unavailable ? Source.camera : null),
          style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
          child: Text(secondary),
        ),
      ],
    ]);
  }
}
