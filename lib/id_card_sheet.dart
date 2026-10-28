import 'dart:io';

import 'package:flutter/material.dart';

import 'capture.dart';
import 'document.dart';
import 'ui.dart';

/// Guides front then back, then makes an ID-card document from the two sides.
Future<void> showIdCardSheet(BuildContext context) async {
  final sides = await showModalBottomSheet<Captured>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const IdCardSheet(),
  );
  if (sides != null && context.mounted) await addCaptured(context, sides, kind: DocKind.idCard);
}

/// Two guided scans, one side each, so the user knows when to flip the card.
class IdCardSheet extends StatefulWidget {
  const IdCardSheet({super.key});

  @override
  State<IdCardSheet> createState() => _IdCardSheetState();
}

class _IdCardSheetState extends State<IdCardSheet> {
  Captured? _front;
  bool _finished = false;

  Future<void> _capture() async {
    final front = _front;
    // The back is taken the way the front was, so a scanner that can't run is explained once (PRD I1).
    final got = await capturePages(context, front?.source ?? Source.scan, pageLimit: 1);
    if (got.paths.isEmpty || !mounted) return;
    if (front == null) {
      // A unique name: on Android a back photo with the same file name would otherwise overwrite it.
      final kept = (await File(got.paths.first).rename('${got.paths.first}.front')).path;
      if (mounted) setState(() => _front = (paths: [kept], source: got.source, skipped: 0));
      return;
    }
    _finished = true;
    // Mixed sources count as photos: the sides aren't scanner-cleaned.
    final source = front.source == got.source ? got.source : Source.photos;
    Navigator.pop<Captured>(context, (paths: [front.paths.first, got.paths.first], source: source, skipped: 0));
  }

  @override
  void dispose() {
    // Closed after the front only: that file isn't wanted any more.
    final front = _front;
    if (!_finished && front != null) File(front.paths.first).delete().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final back = _front != null;
    final action = switch (_front?.source) {
      null => 'Scan front',
      Source.scan => 'Scan back',
      Source.photos => 'Import back',
      Source.camera => 'Take photo of back',
    };
    return sheetBody(context, [
      heading('Scan an ID card', text.headlineSmall),
      const SizedBox(height: 6),
      Text('Both sides go on one page, printed at real card size.', style: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 24),
      _Step(
        n: 1,
        title: 'Front side',
        detail: back ? (_front!.source == Source.scan ? 'Scanned' : 'Added') : 'Place the card on a dark, flat surface',
        done: back,
        active: !back,
        image: _front?.paths.first,
      ),
      const SizedBox(height: 12),
      _Step(n: 2, title: 'Back side', detail: back ? 'Now flip the card over' : 'Next', done: false, active: back, flip: true),
      const SizedBox(height: 28),
      ValueListenableBuilder(
        valueListenable: scanning,
        builder: (context, busy, _) =>
            FilledButton.icon(onPressed: busy ? null : _capture, icon: const Icon(Icons.document_scanner_outlined), label: Text(action)),
      ),
    ]);
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.detail,
    required this.done,
    required this.active,
    this.image,
    this.flip = false,
  });

  final int n;
  final String title, detail;
  final bool done, active, flip;
  final String? image;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dim = !active && !done;
    return Semantics(
      container: true,
      // One sentence per step instead of a loose "1", "Front side", "Scanned".
      label: 'Step $n of 2: $title. $detail',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: active ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: active ? scheme.primary.withValues(alpha: 0.4) : scheme.outlineVariant),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: active || done ? scheme.primary : scheme.surfaceContainerHighest,
                foregroundColor: active || done ? scheme.onPrimary : scheme.onSurfaceVariant,
                child: done ? const Icon(Icons.check, size: 18) : Text('$n', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleMedium!.copyWith(color: dim ? scheme.onSurfaceVariant : null)),
                    const SizedBox(height: 2),
                    Text(detail, style: text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _CardGlyph(image: image, flip: flip, dim: dim),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small ID-1 shaped card: the scanned side once we have it, otherwise a drawn front or back.
class _CardGlyph extends StatelessWidget {
  const _CardGlyph({this.image, required this.flip, required this.dim});

  final String? image;
  final bool flip, dim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = dim ? scheme.outlineVariant : scheme.outline;
    Widget bar(double w) => Container(width: w, height: 4, margin: const EdgeInsets.only(bottom: 4), color: ink);
    return Container(
      width: 70,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: ink),
      ),
      child: image != null
          ? Image.file(File(image!), fit: BoxFit.cover, cacheWidth: 210, excludeFromSemantics: true)
          : Padding(
              padding: const EdgeInsets.all(6),
              child: flip
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 8, color: ink),
                        const Spacer(),
                        bar(40),
                        bar(26),
                      ],
                    )
                  : Row(
                      children: [
                        Container(
                          width: 18,
                          decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [bar(30), bar(22), bar(26)],
                          ),
                        ),
                      ],
                    ),
            ),
    );
  }
}
