import 'dart:io';

import 'package:flutter/material.dart';

import 'capture.dart';
import 'crop_view.dart';
import 'document.dart';
import 'library.dart';
import 'render.dart';
import 'ui.dart';

/// Crop & Enhance: swipe through pages, pick a filter, rotate, crop, retake or delete.
class PageScreen extends StatefulWidget {
  const PageScreen({super.key, required this.docId, this.initialIndex = 0});

  final String docId;
  final int initialIndex;

  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  late final _pager = PageController(initialPage: widget.initialIndex);
  late int _i = widget.initialIndex;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final doc = library.byId(widget.docId);
    if (doc == null || doc.pages.isEmpty) return const Scaffold();
    _i = _i.clamp(0, doc.pages.length - 1);
    final page = doc.pages[_i];
    final scheme = Theme.of(context).colorScheme;
    void update(DocPage p) => library.save(doc.updatePage(_i, p));
    // A landscape phone is too short for the page above the panel (it left ~31 dp, 5 dp at 200 % text), so the panel
    // moves beside the page and scrolls, and the page keeps the full height.
    final wide = MediaQuery.orientationOf(context) == Orientation.landscape;
    final tools = Column(
      children: [
        const SizedBox(height: 12),
        _FilterStrip(
          doc: doc,
          page: page,
          onPick: (f) => update(page.copyWith(filter: f)),
          onApplyAll: () {
            library.save(doc.copyWith(pages: [for (final p in doc.pages) p.copyWith(filter: page.filter)]));
            toast(context, '${page.filter.label} applied to all ${doc.pages.length} pages');
          },
        ),
        const Divider(height: 24, indent: 20, endIndent: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              for (final tool in [
                IconLabelButton(
                  Icons.crop,
                  'Crop',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CropScreen(doc: doc, index: _i),
                    ),
                  ),
                ),
                IconLabelButton(Icons.rotate_right, 'Rotate', () => update(page.copyWith(turns: (page.turns + 1) % 4))),
                IconLabelButton(Icons.camera_alt_outlined, 'Retake', () => replacePage(context, doc.id, page.id, Source.scan)),
                IconLabelButton(Icons.delete_outline, 'Delete', doc.pages.length > 1 ? () => deletePage(context, doc.id, page.id) : null),
              ])
                Expanded(child: tool),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      appBar: AppBar(
        backgroundColor: scheme.surfaceContainer,
        title: Text('Page ${_i + 1} of ${doc.pages.length}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
      body: Flex(
        direction: wide ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.stretch, // landscape: the panel runs the full height, not a floating card
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              right: !wide, // the panel's side: its own SafeArea covers a cutout there
              child: PageView.builder(
                controller: _pager,
                itemCount: doc.pages.length,
                onPageChanged: (i) => setState(() => _i = i),
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 20),
                  child: Center(
                    child: Hero(
                      tag: doc.pages[i].id,
                      child: PageImage(
                        doc: doc,
                        page: doc.pages[i],
                        label: 'Page ${i + 1}, ${doc.pages[i].filter.label}',
                        cacheWidth: 1400,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: wide ? 360 : null,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: wide
                    ? const BorderRadius.horizontal(left: Radius.circular(24))
                    : const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                left: !wide,
                child: wide ? SingleChildScrollView(child: tools) : tools,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({required this.doc, required this.page, required this.onPick, required this.onApplyAll});

  final Document doc;
  final DocPage page;
  final ValueChanged<PageFilter> onPick;
  final VoidCallback onApplyAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
          child: Row(
            children: [
              Text('Filter', style: text.titleSmall),
              const Spacer(),
              if (doc.pages.length > 1) TextButton(onPressed: onApplyAll, child: const Text('Apply to all')),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final f in PageFilter.values)
                Expanded(
                  child: Semantics(
                    selected: f == page.filter,
                    button: true,
                    child: InkWell(
                      onTap: () => onPick(f),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                        child: Column(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 64,
                              height: 72,
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: f == page.filter ? scheme.primary : Colors.transparent, width: 2),
                              ),
                              child: Container(
                                // Hairline paper edge so white pages don't vanish on the white panel.
                                foregroundDecoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: scheme.outlineVariant),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: ColorFiltered(
                                    colorFilter: ColorFilter.matrix(previewMatrix(f)),
                                    // The source plus just this filter, turned like the page.
                                    child: RotatedBox(
                                      quarterTurns: page.turns,
                                      child: Image.file(
                                        File('${doc.dir}/${page.src}'),
                                        cacheWidth: 180,
                                        excludeFromSemantics: true, // the filter's name is on the button
                                        fit: BoxFit.cover,
                                        alignment: Alignment.topCenter,
                                        errorBuilder: (_, _, _) => ColoredBox(color: scheme.surfaceContainer),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            fitLabel(
                              f.label,
                              style: text.labelMedium!.copyWith(
                                color: f == page.filter ? scheme.primary : scheme.onSurfaceVariant,
                                fontWeight: f == page.filter ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
