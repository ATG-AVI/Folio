import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'capture.dart';
import 'document.dart';
import 'export_sheet.dart';
import 'library.dart';
import 'ocr.dart';
import 'page_screen.dart';
import 'ui.dart';

/// Review Pages: reorder, duplicate, replace, delete, add, then export.
class PagesScreen extends StatelessWidget {
  const PagesScreen({super.key, required this.docId, this.notice});

  final String docId;

  /// One-off message from the step that opened this screen, e.g. imports that failed.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final doc = library.byId(docId);
    if (doc == null) return const Scaffold();
    final scheme = Theme.of(context).colorScheme;
    // An ID card has exactly a front and a back; layout() prints only those two.
    final full = doc.kind == DocKind.idCard && doc.pages.length >= 2;
    final idSidesLeft = doc.kind == DocKind.idCard ? 2 - doc.pages.length : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(doc.name),
        actions: [IconButton(tooltip: 'Rename', onPressed: () => renameDocument(context, doc.id), icon: const Icon(Icons.edit_outlined))],
      ),
      // Sides only: landscape cutouts. The bar below pads itself for the gesture bar.
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (notice != null) _Banner(icon: Icons.info_outline, text: notice!),
            if (doc.kind == DocKind.idCard && doc.pages.length == 1)
              const _Banner(icon: Icons.flip_outlined, text: 'Add the back side so both sides print on one page.'),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                buildDefaultDragHandles: false,
                itemCount: doc.pages.length,
                onReorderItem: (from, to) => library.save(doc.movePage(from, to)),
                proxyDecorator: (child, _, _) => Material(
                  color: Colors.transparent,
                  elevation: 8,
                  shadowColor: const Color(0x400B1033),
                  borderRadius: BorderRadius.circular(18),
                  child: child,
                ),
                itemBuilder: (context, i) => Padding(
                  key: ValueKey(doc.pages[i].id),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PageCard(doc: doc, index: i, canAdd: !full),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
          ),
          child: Row(
            children: [
              MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.document_scanner_outlined),
                    onPressed: () => addPages(context, Source.scan, intoId: doc.id, pageLimit: idSidesLeft),
                    child: const Text('Scan pages'),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.photo_library_outlined),
                    onPressed: () => addPages(context, Source.photos, intoId: doc.id, pageLimit: idSidesLeft),
                    child: const Text('Import photos'),
                  ),
                ],
                builder: (context, menu, _) => OutlinedButton.icon(
                  onPressed: full ? null : () => menu.isOpen ? menu.close() : menu.open(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add page'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => showExportSheet(context, doc.id),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Export PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PRD O2: puts the text of one page on the clipboard. It reads the render (what the PDF embeds), so edits count,
/// and a later export finds the lines already cached.
Future<void> copyText(BuildContext context, String docId, String pageId) async {
  final library = LibraryScope.of(context);
  // Only a slow read shows anything before its answer.
  final slow = Timer(const Duration(milliseconds: 300), () => context.mounted ? toast(context, 'Reading text…') : null);
  List<OcrLine>? lines;
  String? path; // the page's render, once it is ready to read
  try {
    String? ready(Document? d) {
      final p = d?.pages.where((p) => p.id == pageId).firstOrNull;
      return p != null && d!.isRendered(p) && File(d.pathOf(p)).existsSync() ? d.pathOf(p) : null;
    }

    // rendered() waits for every page of the document, so only ask it when this page's own render isn't current.
    path = ready(library.byId(docId)) ?? ready(await library.rendered(docId));
    if (path != null) lines = await readText(path);
  } finally {
    slow.cancel();
  }
  if (!context.mounted) return;
  // Still no render after rendered()'s retry: it failed, which is the page's problem, not the recogniser's.
  if (path == null) return toast(context, 'This page couldn’t be prepared. Edit it or try again.');
  if (lines == null) return toast(context, 'Text recognition isn’t available right now. Try again in a minute.');
  if (lines.isEmpty) return toast(context, 'No text found on this page');
  await Clipboard.setData(ClipboardData(text: lines.map((l) => l.text).join('\n')));
  if (context.mounted) toast(context, 'Text copied');
}

class _PageCard extends StatelessWidget {
  const _PageCard({required this.doc, required this.index, required this.canAdd});

  final Document doc;
  final int index;
  final bool canAdd;

  @override
  Widget build(BuildContext context) {
    final page = doc.pages[index];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final library = LibraryScope.of(context);
    final side = doc.kind == DocKind.idCard ? (index == 0 ? 'Front' : 'Back') : null;
    // Card's own semantics wrapper would keep the list's Move up / Move down actions on a node of their own.
    // Here they land on the row itself, the node that has a name and that TalkBack and VoiceOver focus.
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PageScreen(docId: doc.id, initialIndex: index),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  height: 118,
                  child: Center(
                    child: Hero(
                      tag: page.id,
                      child: PageImage(doc: doc, page: page, cacheWidth: 280),
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(side ?? 'Page ${index + 1}', style: text.titleMedium),
                      const SizedBox(height: 4),
                      Text(page.filter.label, style: text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                PopupMenuButton<void>(
                  tooltip: 'Page options',
                  itemBuilder: (_) => [
                    menuItem(context, Icons.copy_outlined, 'Duplicate', enabled: canAdd, () => library.save(doc.duplicatePage(index))),
                    menuItem(context, Icons.text_snippet_outlined, 'Copy text', () => copyText(context, doc.id, page.id)),
                    menuItem(
                      context,
                      Icons.flip_camera_android_outlined,
                      'Replace',
                      () => replacePage(context, doc.id, page.id, Source.photos),
                    ),
                    menuItem(
                      context,
                      Icons.delete_outline,
                      'Delete',
                      destructive: true,
                      enabled: doc.pages.length > 1,
                      () => deletePage(context, doc.id, page.id),
                    ),
                  ],
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(Icons.drag_indicator, color: scheme.outline), // touch only; screen readers use the row's actions
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, color: scheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onPrimaryContainer, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
