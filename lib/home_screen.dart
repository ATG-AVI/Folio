import 'dart:math';

import 'package:flutter/material.dart';

import 'capture.dart';
import 'document.dart';
import 'export_sheet.dart';
import 'id_card_sheet.dart';
import 'library.dart';
import 'pages_screen.dart';
import 'ui.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _query = '';
  DocSort _sort = DocSort.recent;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final docs = library.query(_query, _sort);
    return Scaffold(
      // Sides only: the app bar handles the top and the dock floats above the gesture bar. Landscape cutouts.
      body: SafeArea(
        top: false,
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              expandedHeight: 120,
              title: const Text('Documents'),
              actions: [
                PopupMenuButton<void>(
                  tooltip: 'More',
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      onTap: () => showLicensePage(context: context, applicationName: 'Folio'),
                      child: const Text('About & licences'),
                    ),
                  ],
                ),
              ],
            ),
            if (library.isEmpty)
              const SliverFillRemaining(hasScrollBody: false, child: _EmptyState())
            else ...[
              SliverToBoxAdapter(child: _searchRow()),
              if (docs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text('No documents named “$_query”', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ),
                )
              else
                SliverPadding(
                  // Scrolls clear of the dock, which floats above the gesture bar.
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 108 + MediaQuery.paddingOf(context).bottom),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 210,
                      mainAxisSpacing: 28,
                      crossAxisSpacing: 20,
                      childAspectRatio: 0.53,
                    ),
                    itemCount: docs.length,
                    itemBuilder: (context, i) => _DocTile(docs[i]),
                  ),
                ),
            ],
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: const _Dock(),
    );
  }

  Widget _searchRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
    child: Row(
      children: [
        Expanded(
          // One node for the whole 48dp bar: its text field alone is only 24dp tall.
          child: MergeSemantics(
            child: SearchBar(hintText: 'Search documents', leading: const Icon(Icons.search), onChanged: (q) => setState(() => _query = q)),
          ),
        ),
        PopupMenuButton<DocSort>(
          tooltip: 'Sort',
          icon: const Icon(Icons.swap_vert),
          initialValue: _sort,
          onSelected: (s) => setState(() => _sort = s),
          itemBuilder: (_) => [
            for (final (s, label) in [(DocSort.recent, 'Recent'), (DocSort.name, 'Name')])
              CheckedPopupMenuItem(value: s, checked: s == _sort, child: Text(label)),
          ],
        ),
      ],
    ),
  );
}

class _DocTile extends StatelessWidget {
  const _DocTile(this.doc);

  final Document doc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final n = doc.pages.length;
    // Fixed caption and meta heights on every tile, so thumbnails in a row line up.
    final scaler = MediaQuery.textScalerOf(context);
    final caption = scaler.scale(15) * 1.25 * 2;
    // Page count and date: one line normally, two at large text sizes rather than cutting off the date.
    final meta = max(48.0, scaler.scale(12) * 1.4 * 2);
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            doc.damaged ? _damaged(context) : Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PagesScreen(docId: doc.id))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: doc.damaged ? const _DamagedSheet() : _PaperStack(doc)),
            const SizedBox(height: 12),
            SizedBox(
              height: caption,
              child: Text(doc.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall!.copyWith(height: 1.25)),
            ),
            SizedBox(
              height: meta,
              child: DefaultTextStyle(
                style: text.bodySmall!.copyWith(
                  color: doc.damaged ? scheme.error : scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // The menu's 48dp target overlaps the text's right padding rather than taking its own column.
                child: Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 28),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(doc.damaged ? 'Can’t open' : '${n == 1 ? '1 page' : '$n pages'}   ${_date(context, doc.updatedAt)}'),
                      ),
                    ),
                    if (!doc.damaged) _DocMenu(doc),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _date(BuildContext context, DateTime d) {
    final l = MaterialLocalizations.of(context);
    final now = DateTime.now();
    if (DateUtils.isSameDay(d, now)) return l.formatTimeOfDay(TimeOfDay.fromDateTime(d));
    return d.year == now.year ? l.formatShortMonthDay(d) : l.formatCompactDate(d);
  }

  Future<void> _damaged(BuildContext context) async {
    final delete = await confirmDestructive(
      context,
      title: 'Can’t open this document',
      body: '“${doc.name}” is damaged and can’t be read. You can delete it, or keep it in case it can be recovered later.',
      action: 'Delete',
      cancel: 'Keep',
    );
    if (delete && context.mounted) LibraryScope.of(context).delete(doc.id);
  }
}

/// The first page with up to two sheets peeking out behind it: page count you can see.
class _PaperStack extends StatelessWidget {
  const _PaperStack(this.doc);

  final Document doc;

  @override
  Widget build(BuildContext context) {
    final behind = min(doc.pages.length - 1, 2);
    final aspect = doc.pages.first.aspect.clamp(0.42, 1.7);
    final edge = Theme.of(context).colorScheme.outlineVariant;
    return LayoutBuilder(
      builder: (context, box) {
        const step = 5.0;
        final w = min(box.maxWidth - behind * step, (box.maxHeight - behind * step) * aspect);
        final size = Size(w, w / aspect);
        return Stack(
          clipBehavior: Clip.none, // let back sheets and the contact shadow show
          alignment: Alignment.bottomLeft,
          children: [
            for (var i = behind; i > 0; i--)
              Positioned(
                left: i * step,
                bottom: i * step,
                child: Container(
                  width: size.width,
                  height: size.height,
                  decoration: BoxDecoration(
                    color: Color.lerp(Colors.white, edge, 0.15 * i),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: edge, width: 0.5),
                    boxShadow: paperShadow,
                  ),
                ),
              ),
            SizedBox.fromSize(
              size: size,
              child: PageImage(doc: doc, page: doc.pages.first, cacheWidth: 420),
            ),
          ],
        );
      },
    );
  }
}

class _DamagedSheet extends StatelessWidget {
  const _DamagedSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomLeft,
      child: AspectRatio(
        aspectRatio: 0.71,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Icon(Icons.description_outlined, size: 40, color: scheme.outline),
        ),
      ),
    );
  }
}

class _DocMenu extends StatelessWidget {
  const _DocMenu(this.doc);

  final Document doc;

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final n = doc.pages.length;
    return PopupMenuButton<void>(
      tooltip: 'Options for ${doc.name}',
      iconSize: 20,
      // Icon flush right inside its 48dp target, aligned with the tile edge.
      padding: const EdgeInsets.only(left: 28),
      icon: const Icon(Icons.more_horiz),
      itemBuilder: (_) => [
        menuItem(context, Icons.edit_outlined, 'Rename', () => renameDocument(context, doc.id)),
        menuItem(context, Icons.copy_outlined, 'Duplicate', () => library.duplicate(doc)),
        menuItem(context, Icons.picture_as_pdf_outlined, 'Export PDF', () => showExportSheet(context, doc.id)),
        menuItem(context, Icons.delete_outline, 'Delete', destructive: true, () async {
          final ok = await confirmDestructive(
            context,
            title: 'Delete “${doc.name}”?',
            body: 'This removes the document and its ${n == 1 ? 'page' : '$n pages'} from this phone.',
            action: 'Delete',
          );
          if (ok) library.delete(doc.id);
        }),
      ],
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: scanning,
      builder: (context, busy, _) => Material(
        color: scheme.surfaceContainerLowest,
        elevation: 8,
        shadowColor: const Color(0x400B1033),
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant, width: 0.5)),
        child: Padding(
          padding: const EdgeInsets.all(6),
          // Scales down instead of overflowing on narrow phones at very large text sizes.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconLabelButton(Icons.photo_library_outlined, 'Import', busy ? null : () => addPages(context, Source.photos)),
                FilledButton.icon(
                  onPressed: busy ? null : () => addPages(context, Source.scan),
                  style: FilledButton.styleFrom(minimumSize: const Size(152, 56), padding: const EdgeInsets.symmetric(horizontal: 28)),
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: const Text('Scan'),
                ),
                IconLabelButton(Icons.badge_outlined, 'ID card', busy ? null : () => showIdCardSheet(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget sheet(double angle, Offset at, int lines) => Transform.translate(
      offset: at,
      child: Transform.rotate(
        angle: angle,
        child: Container(
          width: 104,
          height: 140,
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 0),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3), boxShadow: paperShadow),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines; i++)
                Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  height: 4,
                  width: i == 0 ? 44 : (i.isEven ? 76 : 64),
                  decoration: BoxDecoration(color: const Color(0xFFE3E6EC), borderRadius: BorderRadius.circular(2)),
                ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 36, 140),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 190,
            child: Stack(
              alignment: Alignment.center,
              children: [
                sheet(-0.14, const Offset(-38, 8), 7),
                sheet(0.1, const Offset(36, 4), 7),
                sheet(-0.02, Offset.zero, 9),
                // Scanner viewfinder corners framing the front sheet.
                SizedBox(width: 136, height: 172, child: CustomPaint(painter: _Corners(scheme.primary))),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Text('No documents yet', style: text.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Scan paper or import photos to make your first PDF. Everything stays on this phone.',
            textAlign: TextAlign.center,
            style: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Corners extends CustomPainter {
  const _Corners(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    const l = 22.0;
    final p = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (o, dx, dy) in [
      (Offset.zero, 1, 1),
      (Offset(s.width, 0), -1, 1),
      (Offset(s.width, s.height), -1, -1),
      (Offset(0, s.height), 1, -1),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(o.dx, o.dy + dy * l)
          ..lineTo(o.dx, o.dy)
          ..lineTo(o.dx + dx * l, o.dy),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_Corners old) => old.color != color;
}
