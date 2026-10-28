import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';

import 'document.dart';
import 'render.dart';

enum DocSort { recent, name }

/// All documents: one folder per document under [root], each with a `doc.json` manifest
/// (plan §5). Kept in memory; every change is written through a serial queue with atomic renames.
class Library extends ChangeNotifier {
  /// [docs] seeds memory without touching disk (tests, fixtures). Use [open] to load from disk.
  Library(this.root, {Iterable<Document> docs = const [], this.onError}) {
    for (final d in docs) {
      _docs[d.id] = d;
    }
  }

  static Future<Library> open(String root, {void Function(Object error)? onError}) async {
    final library = Library(root, onError: onError);
    await library._load();
    return library;
  }

  final String root;

  /// Called when a background write fails. The in-memory document stays correct and the
  /// next save rewrites the whole manifest, so a transient failure heals itself.
  void Function(Object error)? onError;

  final _docs = <String, Document>{};

  // Limit: one global write queue; per-document queues if writes ever become a bottleneck.
  Future<void> _tail = Future.value();

  /// Queues [job]. The returned future fails if the job fails, for callers that must know
  /// (ingest keeps its inputs). The queue itself reports the error once and carries on.
  Future<void> _run(Future<void> Function() job) {
    final done = _tail.then((_) => job());
    _tail = done.catchError((Object e) => onError?.call(e));
    return done;
  }

  /// Completes when every queued write has finished.
  Future<void> flush() => _tail;

  bool get isEmpty => _docs.isEmpty;

  Document? byId(String id) => _docs[id];

  List<Document> query(String q, DocSort sort) {
    final s = q.trim().toLowerCase();
    return [
      for (final d in _docs.values)
        if (d.name.toLowerCase().contains(s)) d,
    ]..sort(
      sort == DocSort.name ? (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()) : (a, b) => b.updatedAt.compareTo(a.updatedAt),
    );
  }

  /// A new, unsaved, empty document with its own folder path. Add pages, then [save].
  Document newDocument({String? name, DocKind kind = DocKind.document}) {
    final id = newId(), now = DateTime.now();
    return Document(id: id, dir: '$root/$id', name: name ?? defaultName(now), kind: kind, createdAt: now, updatedAt: now, pages: const []);
  }

  /// Copies an image into [doc]'s `src/` folder as a JPEG (see normalizeSync) and returns its page;
  /// throws if it isn't an image. Copy, not move: until a manifest that uses the page is saved, the
  /// caller's file is the only safe copy (a crash before that leaves an orphan the next load sweeps).
  Future<DocPage> addImage(Document doc, String path) async {
    final src = 'src/${newId()}.jpg';
    await Directory('${doc.dir}/src').create(recursive: true);
    final (w, h) = await _normalize(path, '${doc.dir}/$src');
    return DocPage(id: newId(), src: src, w: w, h: h);
  }

  /// Updates memory at once (the UI never waits), queues the write, and re-renders changed pages.
  Future<void> save(Document d) {
    final doc = d.copyWith(updatedAt: DateTime.now());
    _docs[doc.id] = doc;
    notifyListeners();
    _failed.removeAll(doc.pages.map(doc.renderKey)); // editing a document retries its failed renders
    _scheduleRenders(doc, checkFiles: true); // also brings back a shared render deleted under an Undo
    // Never write a damaged entry: that would overwrite the manifest it couldn't read.
    return doc.damaged ? Future.value() : _run(() => _writeManifest(doc.dir, doc));
  }

  // Renders (plan §7): one page at a time in a background isolate, each named by its edit params.
  final _toRender = <(String, String)>{}; // (docId, pageId), oldest first
  final _failed = <String>{}; // render keys that failed; retried on the next save
  Future<void>? _rendering;
  String? _priority; // the document an export is waiting for: its pages render before everyone else's
  (String, String)? _current; // the key being rendered right now; it's in neither _toRender nor done

  /// True while [p] waits for a render that matches its current edits (the UI shows progress).
  bool isRendering(Document d, DocPage p) => !d.damaged && !d.isRendered(p) && !_failed.contains(d.renderKey(p));

  /// True when [p]'s latest edit couldn't be rendered; the page still shows its previous image.
  bool renderFailed(Document d, DocPage p) => !d.isRendered(p) && _failed.contains(d.renderKey(p));

  /// Counts finished renders. Images key on it, so a render re-created at a path that earlier failed
  /// to load (an Undo, a missing file found at launch) is loaded again rather than left showing an error.
  int renders = 0;

  /// Completes when no render is queued or running.
  Future<void> renderIdle() => _rendering ?? Future.value();

  /// Document [id] once every page has had a render attempt: failed renders are retried and missing
  /// render files re-created, so an export's "Try again" can succeed. Null if the document is gone.
  /// Its renders jump the queue and nothing else is waited for: a finished document exports at once
  /// while another one's import backlog renders. (One export at a time; the sheet allows no more.)
  Future<Document?> rendered(String id) async {
    final d = _docs[id];
    if (d == null) return null;
    _failed.removeAll(d.pages.map(d.renderKey));
    _scheduleRenders(d, checkFiles: true);
    _priority = id;
    final done = Completer<void>();
    void check() {
      if (!done.isCompleted && _current?.$1 != id && !_toRender.any((k) => k.$1 == id)) done.complete();
    }

    addListener(check); // every finished or failed render notifies...
    renderIdle().then((_) => check()); // ...but a skipped key doesn't, and by the time the queue is idle none is left
    check();
    await done.future;
    removeListener(check);
    if (_priority == id) _priority = null;
    return _docs[id];
  }

  void _scheduleRenders(Document d, {bool checkFiles = false}) {
    if (d.damaged) return;
    for (final p in d.pages) {
      if (!d.isRendered(p) || (checkFiles && !File(d.pathOf(p)).existsSync())) _toRender.add((d.id, p.id));
    }
    if (_toRender.isNotEmpty) _rendering ??= _renderAll();
  }

  Future<void> _renderAll() async {
    await Future<void>.value(); // yield first, so _rendering is set before this can clear it
    while (_toRender.isNotEmpty) {
      // An export's document first, then edited pages: they're on screen showing an outdated render.
      // New pages show their source meanwhile.
      final next = _toRender.firstWhere(
        (k) => k.$1 == _priority,
        orElse: () =>
            _toRender.firstWhere((k) => _docs[k.$1]?.pages.any((p) => p.id == k.$2 && p.r != null) ?? false, orElse: () => _toRender.first),
      );
      _toRender.remove(next);
      final (docId, pageId) = next;
      final d = _docs[docId];
      final p = d?.pages.where((p) => p.id == pageId).firstOrNull;
      // A skip doesn't notify, but rendered() may be waiting on exactly this key.
      void skip() => docId == _priority ? notifyListeners() : null;
      if (d == null || p == null) {
        skip();
        continue;
      }
      final key = d.renderKey(p), out = '${d.dir}/cache/$key.jpg';
      if ((p.r == key && File(out).existsSync()) || _failed.contains(key)) {
        skip();
        continue;
      }
      final (edge, quality) = d.renderPreset;
      _current = next;
      try {
        await Directory('${d.dir}/cache').create(recursive: true);
        final (w, h) = await _render((
          src: '${d.dir}/${p.src}',
          out: out,
          corners: p.corners,
          turns: p.turns,
          filter: p.filter,
          maxEdge: edge,
          quality: quality,
        ));
        _current = null; // before notifying: rendered() looks at it then
        _applyRender(docId, pageId, key, w, h);
      } catch (_) {
        _failed.add(key); // unreadable or missing source: the page shows as missing instead of spinning
        _current = null;
        notifyListeners();
      }
    }
    _rendering = null;
  }

  void _applyRender(String docId, String pageId, String key, int w, int h) {
    final d = _docs[docId];
    final i = d?.pages.indexWhere((p) => p.id == pageId) ?? -1;
    if (d == null || i < 0 || d.renderKey(d.pages[i]) != key) return; // edited meanwhile; the newer render is queued
    final old = d.pages[i].renderPath;
    // Not save(): a render isn't an edit, so the document's modified date stays put.
    final doc = d.updatePage(i, d.pages[i].copyWith(r: key, w: w, h: h));
    _docs[docId] = doc;
    renders++;
    notifyListeners();
    _run(() async {
      await _writeManifest(doc.dir, doc);
      // Decide against the document as it is now: duplicated pages share renders, and an Undo may have
      // brought a page back that still uses the old one.
      final now = _docs[docId];
      if (old != null && now != null && !_referenced(now).contains(old)) {
        await File('${doc.dir}/$old').delete().catchError((Object _) => File(old));
      }
    });
  }

  // Static, so the isolate closures capture only plain values, never this Library.
  static Future<(int, int)> _render(RenderSpec spec) => Isolate.run(() => renderSync(spec));

  static Future<(int, int)> _normalize(String from, String to) => Isolate.run(() => normalizeSync(from, to));

  Future<void> delete(String id) {
    final doc = _docs.remove(id);
    notifyListeners();
    if (doc == null) return _tail;
    // Rename first: a crash mid-delete leaves `<id>.tmp`, which the next load sweeps.
    return _run(() async {
      final dir = Directory(doc.dir);
      if (await dir.exists()) await (await dir.rename('${doc.dir}.tmp')).delete(recursive: true);
    });
  }

  /// Copies the folder (only the files the manifest uses) under a new id, then shows the copy.
  Future<void> duplicate(Document d) => _run(() async {
    final id = newId(), now = DateTime.now();
    final dir = '$root/$id', tmp = '$dir.tmp';
    final copy = d.copyWith(id: id, dir: dir, name: '${d.name} copy', createdAt: now, updatedAt: now);
    await Directory(tmp).create(recursive: true);
    for (final rel in _referenced(d)) {
      final from = File('${d.dir}/$rel');
      if (!await from.exists()) continue; // A missing render is rebuilt; a missing src shows as missing.
      await Directory('$tmp/${rel.split('/').first}').create(recursive: true);
      await _copyDurably(from, '$tmp/$rel');
    }
    await _writeManifest(tmp, copy);
    await Directory(tmp).rename(dir); // the copy appears all at once or not at all
    _docs[id] = copy;
    notifyListeners();
    _scheduleRenders(copy, checkFiles: true);
  });

  static Future<void> _writeManifest(String dir, Document doc) async {
    await Directory(dir).create(recursive: true);
    final tmp = File('$dir/doc.json.tmp');
    await tmp.writeAsString(jsonEncode(doc.toJson()), flush: true);
    await tmp.rename('$dir/doc.json'); // atomic replace: a reader sees the old or the new manifest, never half
  }

  Future<void> _load() async {
    final dir = Directory(root);
    await dir.create(recursive: true);
    await for (final e in dir.list()) {
      if (e is! Directory) continue;
      final id = e.path.split('/').last;
      // `.tmp`: a duplicate or delete that never finished. No doc.json: a new document whose first
      // save never landed; it holds only copies, and its inputs are still where they were.
      if (id.endsWith('.tmp') || !await File('${e.path}/doc.json').exists()) {
        await e.delete(recursive: true).catchError((Object _) => e);
        continue;
      }
      final doc = await _read(e.path, id);
      _docs[id] = doc;
      if (!doc.damaged) await _sweep(doc).catchError((Object _) {}); // best effort; retried next launch
    }
    for (final d in _docs.values) {
      _scheduleRenders(d, checkFiles: true); // missing or stale renders, e.g. after a crash mid-render
    }
  }

  /// A manifest that can't be read (or is from a newer app version) becomes a "damaged" entry.
  /// Damaged entries are never saved or swept, so their files survive until the app can read them.
  static Future<Document> _read(String dir, String id) async {
    try {
      final json = jsonDecode(await File('$dir/doc.json').readAsString()) as Map<String, Object?>;
      final doc = Document.fromJson(json, id: id, dir: dir);
      if (doc.pages.isNotEmpty) return doc;
    } catch (_) {
      // Fall through: missing, truncated or malformed manifest.
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return Document(id: id, dir: dir, name: 'Unreadable document', createdAt: epoch, updatedAt: epoch, pages: const [], damaged: true);
  }

  /// Deletes files no manifest points at: replaced or deleted pages, stale renders, interrupted writes.
  static Future<void> _sweep(Document doc) async {
    final keep = _referenced(doc);
    for (final sub in ['src', 'cache']) {
      final d = Directory('${doc.dir}/$sub');
      if (!await d.exists()) continue;
      await for (final f in d.list()) {
        if (!keep.contains('$sub/${f.path.split('/').last}')) await f.delete(recursive: true);
      }
    }
    final tmp = File('${doc.dir}/doc.json.tmp');
    if (await tmp.exists()) await tmp.delete();
  }

  /// Copy + fsync, so a manifest written afterwards never points at data still in the OS cache
  /// (power loss right after the manifest lands would otherwise leave an empty page file).
  static Future<void> _copyDurably(File from, String to) async {
    final f = await (await from.copy(to)).open(mode: FileMode.append);
    try {
      await f.flush();
    } finally {
      await f.close();
    }
  }

  static Set<String> _referenced(Document d) => {
    for (final p in d.pages) ...[p.src, ?p.renderPath],
  };
}

/// `Scan 2026-10-27 18.40` (PRD X4).
String defaultName(DateTime t, [String prefix = 'Scan']) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '$prefix ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}';
}

class LibraryScope extends InheritedNotifier<Library> {
  const LibraryScope({super.key, required Library super.notifier, required super.child});

  static Library of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
}
