import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart' show Printing;

import 'capture.dart' show storageFull;
import 'document.dart';
import 'library.dart';
import 'native.dart';
import 'ocr.dart';
import 'pdf.dart';
import 'ui.dart';

Future<void> showExportSheet(BuildContext context, String docId) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ExportSheet(docId: docId),
);

const _qualityHint = {
  Quality.small: 'Smallest file. Clear on screen.',
  Quality.standard: 'Sharp text at a small size. Good for email and forms.',
  Quality.high: 'Most detail, larger file. Best for printing.',
};

/// "340 KB" under 1 MB (at least 1), else "1.2 MB".
String sizeText(int bytes) {
  final kb = (bytes / 1024).round();
  return kb < 1024 ? '${max(1, kb)} KB' : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
}

/// How long one page may take to read before it simply has no text (the model may be downloading).
@visibleForTesting
var ocrTimeout = const Duration(seconds: 20);

enum _Out { share, save, print }

class ExportSheet extends StatefulWidget {
  const ExportSheet({super.key, required this.docId});

  final String docId;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  late final _name = TextEditingController(text: LibraryScope.of(context).byId(widget.docId)!.name);

  final _shareKey = GlobalKey();

  /// The export in flight. Cancel (or closing the sheet) clears it, and the stale run then drops its result.
  Object? _job;
  String? _error;

  /// The export is in its text-recognition step rather than building the PDF.
  var _reading = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Still wanted: not cancelled, and the sheet still on screen. A closed sheet (drag, back, barrier) stays
  /// mounted ~200 ms while it animates out; acting then would pop the route below it.
  bool _live(Object job) => mounted && _job == job && (ModalRoute.of(context)?.isActive ?? false);

  void _end(Object job, [String? error]) {
    if (_live(job)) {
      setState(() {
        _job = null;
        _error = error;
      });
    }
  }

  Future<void> _export(_Out out) async {
    final library = LibraryScope.of(context);
    // A snackbar shown under the sheet is hidden, so it's shown after the sheet is gone, through this.
    final messenger = ScaffoldMessenger.of(context), nav = Navigator.of(context);
    final job = Object();
    setState(() {
      _job = job;
      _error = null;
      _reading = false;
    });
    File? file;
    try {
      final doc = await library.rendered(widget.docId);
      if (!_live(job)) return;
      bool ready(DocPage p) => doc!.isRendered(p) && File(doc.pathOf(p)).existsSync();
      if (doc == null || !doc.pages.every(ready)) return _end(job, 'Some pages couldn’t be prepared. Try again.');
      final built = await _build(doc, job);
      if (built == null || !_live(job)) return; // cancelled: nothing has been written anywhere (PRD X9)
      final bytes = built.bytes;
      final name = '${fileNameFor(_name.text)}.pdf';
      switch (out) {
        case _Out.share:
          final box = _shareKey.currentContext!.findRenderObject()! as RenderBox; // the iPad popover anchors here
          await Printing.sharePdf(bytes: bytes, filename: name, bounds: box.localToGlobal(Offset.zero) & box.size);
        case _Out.print:
          // On Android layoutPdf only completes when the print job leaves the queue (and fails for an offline
          // printer), so the sheet is done once the dialog has asked for the pages.
          final handed = Completer<void>();
          final printing = Printing.layoutPdf(
            onLayout: (_) async {
              if (!handed.isCompleted) handed.complete();
              return bytes;
            },
            name: name,
          );
          await Future.any([handed.future, printing]); // a failure before the layout still throws
        case _Out.save:
          final dir = Directory('${(await getTemporaryDirectory()).path}/folio');
          await dir.create(recursive: true);
          file = await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
          if (!_live(job)) return;
          if (!await Native.saveAs(file.path, name)) return _end(job); // picked nothing: stay and let them retry
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('Saved · ${sizeText(bytes.length)}${built.noText ? ' · without searchable text' : ''}')));
      }
      if (_live(job)) nav.pop();
    } catch (e) {
      _end(
        job,
        storageFull(e)
            ? 'Not enough storage on this phone to export. Free some space and try again.'
            : 'Couldn’t export the PDF. Try again.',
      );
    } finally {
      if (file != null) await file.delete().catchError((Object _) => file!);
    }
  }

  /// The PDF, with its text layer when the document asks for one. Null = cancelled while reading. [noText]: asked
  /// for, not delivered (nothing recognised, or the layer failed): OCR never blocks an export.
  Future<({Uint8List bytes, bool noText})?> _build(Document doc, Object job) async {
    if (!doc.searchable) return (bytes: await buildPdf(doc), noText: false);
    setState(() => _reading = true);
    final text = <String, List<OcrLine>>{};
    for (final page in layout(doc)) {
      for (final (p, _) in page.images) {
        final path = doc.pathOf(p);
        if (text.containsKey(path)) continue; // a duplicated page shares its render
        // A failure, a timeout or no recogniser: this page gets no text and the export carries on.
        text[path] = await readText(path).timeout(ocrTimeout, onTimeout: () => null) ?? const [];
        if (!_live(job)) return null; // Cancel works between pages
      }
    }
    setState(() => _reading = false);
    final built = await buildSearchablePdf(doc, text);
    return (bytes: built.bytes, noText: !built.textLayer);
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final doc = library.byId(widget.docId)!;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final busy = _job != null;
    final idCard = doc.kind == DocKind.idCard; // A4 or Letter only: Fit prints as A4 (PRD I2)
    Widget label(String s) => Padding(padding: const EdgeInsets.only(bottom: 8), child: heading(s, text.titleSmall));
    return sheetBody(context, [
      Row(
        children: [
          Expanded(child: heading('Export PDF', text.headlineSmall)),
          TextButton.icon(
            onPressed: busy ? null : () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PreviewScreen(docId: doc.id))),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Preview'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _name,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
        textCapitalization: TextCapitalization.sentences,
      ),
      const SizedBox(height: 22),
      label('Page size'),
      SegmentedButton<PageSize>(
        showSelectedIcon: false,
        segments: [
          if (!idCard) ButtonSegment(value: PageSize.fit, label: fitLabel('Fit')),
          ButtonSegment(value: PageSize.a4, label: fitLabel('A4')),
          ButtonSegment(value: PageSize.letter, label: fitLabel('Letter')),
        ],
        selected: {idCard && doc.pageSize == PageSize.fit ? PageSize.a4 : doc.pageSize},
        onSelectionChanged: busy ? null : (s) => library.save(doc.copyWith(pageSize: s.single)),
      ),
      const SizedBox(height: 22),
      label('Quality'),
      SegmentedButton<Quality>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: Quality.small, label: fitLabel('Small')),
          ButtonSegment(value: Quality.standard, label: fitLabel('Standard')),
          ButtonSegment(value: Quality.high, label: fitLabel('High')),
        ],
        selected: {doc.quality},
        onSelectionChanged: busy ? null : (s) => library.save(doc.copyWith(quality: s.single)),
      ),
      const SizedBox(height: 8),
      Text(_qualityHint[doc.quality]!, style: text.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Searchable text'),
        subtitle: const Text('Adds hidden text so the PDF can be searched and copied.'),
        value: doc.searchable,
        onChanged: busy ? null : (v) => library.save(doc.copyWith(searchable: v)),
      ),
      if (busy) ...[
        const SizedBox(height: 16),
        Row(
          children: [
            // Live regions: they appear with no focus change, so a screen reader would stay silent otherwise.
            Expanded(
              child: Semantics(liveRegion: true, child: Text(_reading ? 'Reading text…' : 'Preparing PDF…', style: text.bodyMedium)),
            ),
            TextButton(onPressed: () => setState(() => _job = null), child: const Text('Cancel')),
          ],
        ),
        const LinearProgressIndicator(minHeight: 3, semanticsLabel: 'Preparing PDF'),
      ] else if (_error != null) ...[
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(_error!, style: text.bodyMedium!.copyWith(color: scheme.error)),
        ),
      ],
      const SizedBox(height: 28),
      FilledButton.icon(
        key: _shareKey,
        onPressed: busy ? null : () => _export(_Out.share),
        icon: const Icon(Icons.ios_share),
        label: const Text('Share'),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => _export(_Out.save),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Save to device'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => _export(_Out.print),
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print'),
            ),
          ),
        ],
      ),
    ]);
  }
}

/// Exactly what the PDF will contain, drawn from the same layout() as the export.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key, required this.docId});

  final String docId;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  var _i = 0;

  @override
  Widget build(BuildContext context) {
    final doc = LibraryScope.of(context).byId(widget.docId)!;
    final pages = layout(doc);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      appBar: AppBar(backgroundColor: scheme.surfaceContainer, title: const Text('Preview')),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: PageView.builder(
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _i = i),
                itemBuilder: (context, i) {
                  final p = pages[i];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                    child: Center(
                      child: Semantics(
                        label: 'Page ${i + 1} of ${pages.length}',
                        image: true,
                        child: AspectRatio(
                          aspectRatio: p.size.aspectRatio,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(color: Colors.white, boxShadow: paperShadow),
                            child: FittedBox(
                              child: SizedBox.fromSize(
                                size: p.size,
                                child: Stack(
                                  children: [
                                    for (final (page, rect) in p.images)
                                      Positioned.fromRect(
                                        rect: rect,
                                        child: PageImage(doc: doc, page: page, cacheWidth: 1200, radius: 0, lifted: false),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: ExcludeSemantics(
                // Each page already says "Page 1 of 3".
                child: Text(
                  '${_i + 1} of ${pages.length}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
