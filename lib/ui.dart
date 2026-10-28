import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'document.dart';
import 'library.dart';
import 'render.dart';

/// Shared widgets and small UI helpers used by more than one screen.

const paperShadow = [
  BoxShadow(color: Color(0x14000000), blurRadius: 1, offset: Offset(0, 0.5)),
  BoxShadow(color: Color(0x1F0B1033), blurRadius: 14, offset: Offset(0, 6)),
];

/// One page as a sheet of paper: real proportions, white stock, soft contact shadow.
class PageImage extends StatelessWidget {
  const PageImage({
    super.key,
    required this.doc,
    required this.page,
    this.label,
    this.cacheWidth = 600,
    this.radius = 3,
    this.lifted = true,
  });

  final Document doc;
  final DocPage page;

  /// What a screen reader says for this image. Null when the surroundings already name the page.
  final String? label;
  final int cacheWidth;
  final double radius;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final library = LibraryScope.of(context);
    Widget image = Image.file(
      key: ValueKey(library.renders),
      File(doc.pathOf(page)),
      cacheWidth: cacheWidth,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      excludeFromSemantics: true, // [label] speaks for it
      errorBuilder: (context, _, _) => const _Missing(),
    );
    // A render has rotation and filter baked in. Before the first render, preview them on the GPU.
    if (page.r == null) {
      image = ColorFiltered(
        colorFilter: ColorFilter.matrix(previewMatrix(page.filter)),
        child: RotatedBox(quarterTurns: page.turns, child: image),
      );
    }
    final rendering = library.isRendering(doc, page), failed = library.renderFailed(doc, page);
    final sheet = AspectRatio(
      aspectRatio: page.aspect,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, borderRadius: r, boxShadow: lifted ? paperShadow : null),
        child: ClipRRect(
          borderRadius: r,
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              // Shows the previous image until the new render lands, with a thin bar so edits feel acknowledged.
              if (rendering) const Align(alignment: Alignment.bottomCenter, child: LinearProgressIndicator(minHeight: 3)),
              if (failed)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Tooltip(
                      message: 'Couldn’t update this page. Edit it again to retry.',
                      child: Icon(Icons.error, size: 18, color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return label == null ? sheet : Semantics(label: label, image: true, child: sheet);
  }
}

class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFEEF0F4),
    // Scales down in a small box (a landscape phone's pager) instead of overflowing.
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, color: Color(0xFF7A8193)),
            const SizedBox(height: 6),
            Text(
              'Page image missing',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall!.copyWith(color: const Color(0xFF596074)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Icon over a short label; dims when [onTap] is null. Used by the Home dock and the editor tools.
class IconLabelButton extends StatelessWidget {
  const IconLabelButton(this.icon, this.label, this.onTap, {super.key});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onTap == null ? theme.disabledColor : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72, minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(height: 4),
                fitLabel(
                  label,
                  style: theme.textTheme.labelMedium!.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Standard bottom-sheet body: clear of the home indicator and keyboard, scrolls at large text sizes.
Widget sheetBody(BuildContext context, List<Widget> children) => SafeArea(
  child: SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  ),
);

/// A one-line label that shrinks at large text sizes instead of breaking a word or ending in an ellipsis.
Widget fitLabel(String text, {TextStyle? style}) => FittedBox(
  fit: BoxFit.scaleDown,
  child: Text(text, maxLines: 1, style: style),
);

/// A sheet or section title that screen readers can jump to.
Widget heading(String text, TextStyle? style) => Semantics(header: true, child: Text(text, style: style));

void toast(BuildContext context, String message, {SnackBarAction? action}) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(
    // Action snackbars stay up for screen-reader users, who need time to reach Undo.
    SnackBar(content: Text(message), action: action, persist: action != null && MediaQuery.accessibleNavigationOf(context)),
  );

/// A dialog rather than a snackbar: it stays visible above bottom sheets.
Future<void> alert(BuildContext context, String title, String body) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: Text(title),
    content: Text(body),
    actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
  ),
);

PopupMenuItem<void> menuItem(
  BuildContext context,
  IconData icon,
  String label,
  VoidCallback onTap, {
  bool destructive = false,
  bool enabled = true,
}) {
  final color = destructive ? Theme.of(context).colorScheme.error : null;
  return PopupMenuItem(
    onTap: onTap,
    enabled: enabled,
    child: ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
    ),
  );
}

Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  String cancel = 'Cancel',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialog).colorScheme.error),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<void> renameDocument(BuildContext context, String docId) async {
  final library = LibraryScope.of(context);
  var name = library.byId(docId)!.name;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Rename'),
      content: TextFormField(
        initialValue: name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        textCapitalization: TextCapitalization.sentences,
        onChanged: (v) => name = v,
        onFieldSubmitted: (_) => Navigator.pop(dialog, true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Save')),
      ],
    ),
  );
  final doc = library.byId(docId);
  if (ok == true && doc != null && name.trim().isNotEmpty) library.save(doc.copyWith(name: name.trim()));
}

/// Deletes one page with Undo. Undo re-inserts just that page into the current document,
/// so edits made in the meantime survive.
void deletePage(BuildContext context, String docId, String pageId) {
  final library = LibraryScope.of(context);
  final doc = library.byId(docId)!;
  final i = doc.pages.indexWhere((p) => p.id == pageId);
  final page = doc.pages[i];
  // Captured now: [context] may be the deleted page's card, gone by the time Undo is tapped.
  final messenger = ScaffoldMessenger.of(context);
  library.save(doc.removePage(i));
  toast(
    context,
    'Page ${i + 1} deleted',
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () {
        final now = library.byId(docId);
        if (now == null) return;
        if (now.kind == DocKind.idCard && now.pages.length >= 2) {
          messenger.showSnackBar(const SnackBar(content: Text('This ID card already has two sides'), persist: false));
          return;
        }
        library.save(now.copyWith(pages: [...now.pages]..insert(min(i, now.pages.length), page)));
      },
    ),
  );
}
