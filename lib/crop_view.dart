import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'document.dart';
import 'library.dart';
import 'native.dart';
import 'render.dart';
import 'ui.dart';

const _full = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0];
const _cornerNames = ['top left', 'top right', 'bottom right', 'bottom left'];

/// 4-corner crop over the original image. Corners are normalised TL, TR, BR, BL.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.doc, required this.index});

  /// Snapshot used for the source path and starting corners; saving re-reads the latest document.
  final Document doc;
  final int index;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late final _page = widget.doc.pages[widget.index];
  late final _path = '${widget.doc.dir}/${_page.src}';
  late final _start = _page.corners ?? _full;
  late var _q = [..._start];
  Size? _src;
  int? _drag;

  @override
  void initState() {
    super.initState();
    _sourceSize(_path).then(
      (s) => mounted ? setState(() => _src = s) : null,
      onError: (Object _) {
        if (!mounted) return;
        toast(context, 'Page image missing. Replace or delete this page.');
        Navigator.pop(context);
      },
    );
  }

  /// Upright size of the original, read in a background isolate (same rules as the renderer).
  static Future<Size> _sourceSize(String path) async {
    final (w, h) = await Isolate.run(() => uprightSize(File(path).readAsBytesSync()));
    return Size(w.toDouble(), h.toDouble());
  }

  void _save() {
    final library = LibraryScope.of(context);
    final doc = library.byId(widget.doc.id);
    // By id, not index: the page list may have changed while this screen was open.
    final i = doc?.pages.indexWhere((p) => p.id == _page.id) ?? -1;
    if (i >= 0) library.save(doc!.updatePage(i, doc.pages[i].copyWith(corners: _q)));
    Navigator.pop(context);
  }

  /// Moves corner [i] by a fraction of the image, staying inside it.
  void _move(int i, double dx, double dy) => setState(() {
    _q[i * 2] = (_q[i * 2] + dx).clamp(0.0, 1.0);
    _q[i * 2 + 1] = (_q[i * 2 + 1] + dy).clamp(0.0, 1.0);
  });

  Future<void> _auto() async {
    final c = await Native.detectCorners(_path);
    if (!mounted) return;
    c == null ? toast(context, 'No document edges found. Drag the corners instead.') : setState(() => _q = c);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final valid = isConvex(_q);
    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      appBar: AppBar(
        backgroundColor: scheme.surfaceContainer,
        title: const Text('Crop'),
        actions: [TextButton(onPressed: valid && _src != null ? _save : null, child: const Text('Done'))],
      ),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: _src == null
                    ? const SizedBox.expand()
                    : LayoutBuilder(builder: (context, box) => _editor(box.biggest, valid, scheme)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: AnimatedOpacity(
              opacity: valid ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              // A live region: it fades in with no focus change, so a screen reader would never mention it. Hidden at
              // opacity 0 (AnimatedOpacity leaves alwaysIncludeSemantics false), so it only speaks while it shows.
              child: Semantics(
                container: true,
                liveRegion: true,
                child: Text(
                  'Corners must make a four-sided shape',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              // Wraps to a second line at large text sizes instead of overflowing.
              child: Wrap(
                alignment: WrapAlignment.spaceEvenly,
                children: [
                  // Android has no edge detection (detectCorners is always null there), so Auto could only fail.
                  if (!Platform.isAndroid)
                    TextButton.icon(onPressed: _auto, icon: const Icon(Icons.auto_fix_high_outlined), label: const Text('Auto')),
                  TextButton.icon(
                    onPressed: () => setState(() => _q = [..._full]),
                    icon: const Icon(Icons.fullscreen),
                    label: const Text('Full'),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _q = [..._start]),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(Size box, bool valid, ColorScheme scheme) {
    // Keep 24dp around the image so every 48dp handle is fully touchable, even at the image edge.
    final area = (Offset.zero & box).deflate(24);
    final rect = Alignment.center.inscribe(applyBoxFit(BoxFit.contain, _src!, area.size).destination, area);
    Offset at(int i) => Offset(rect.left + _q[i * 2] * rect.width, rect.top + _q[i * 2 + 1] * rect.height);
    final drag = _drag == null ? null : at(_drag!);
    // Loupe sits above the finger, or below it near the top edge.
    const lens = 112.0, lift = 96.0;
    final below = drag != null && drag.dy - lift - lens / 2 < 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fromRect(
          rect: rect,
          child: DecoratedBox(
            decoration: const BoxDecoration(boxShadow: paperShadow),
            child: Image.file(File(_path), fit: BoxFit.fill, cacheWidth: 1400, semanticLabel: 'Page ${widget.index + 1}'),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _QuadPainter([for (var i = 0; i < 4; i++) at(i)], rect, valid ? scheme.primary : scheme.error, _drag),
            ),
          ),
        ),
        for (var i = 0; i < 4; i++)
          Positioned(
            left: at(i).dx - 24,
            top: at(i).dy - 24,
            width: 48,
            height: 48,
            child: Semantics(
              label: 'Crop corner, ${_cornerNames[i]}',
              value: '${(_q[i * 2] * 100).round()} percent from the left, ${(_q[i * 2 + 1] * 100).round()} percent from the top',
              // A drag can't be done from a screen reader: nudge by 2 % of the page instead.
              customSemanticsActions: {
                for (final (name, dx, dy) in [('left', -1, 0), ('right', 1, 0), ('up', 0, -1), ('down', 0, 1)])
                  CustomSemanticsAction(label: 'Move $name'): () => _move(i, dx * 0.02, dy * 0.02),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => setState(() => _drag = i),
                onPanUpdate: (d) => _move(i, d.delta.dx / rect.width, d.delta.dy / rect.height),
                onPanEnd: (_) => setState(() => _drag = null),
                onPanCancel: () => setState(() => _drag = null),
              ),
            ),
          ),
        if (drag != null)
          Positioned(
            left: drag.dx - lens / 2,
            top: drag.dy - lens / 2 + (below ? lift : -lift),
            child: RawMagnifier(
              size: const Size.square(lens),
              magnificationScale: 2.2,
              clipBehavior: Clip.antiAlias, // keeps the lens shadow outside the lens
              focalPointOffset: Offset(0, below ? -lift : lift),
              decoration: MagnifierDecoration(
                shape: CircleBorder(side: BorderSide(color: scheme.primary, width: 2.5)),
                shadows: paperShadow,
              ),
              // Unmagnified crosshair marks the exact point being placed.
              child: const Center(
                child: Icon(
                  Icons.add,
                  size: 22,
                  color: Colors.white,
                  shadows: [Shadow(color: Color(0xCC000000), blurRadius: 2)],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _QuadPainter extends CustomPainter {
  const _QuadPainter(this.points, this.image, this.color, this.active);

  final List<Offset> points;
  final Rect image;
  final Color color;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final quad = Path()..addPolygon(points, true);
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(image), quad), Paint()..color = const Color(0x8C0B0D14));
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(quad, stroke);
    for (var i = 0; i < 4; i++) {
      if (i == active) continue; // The loupe shows this corner; a handle would hide it.
      canvas.drawCircle(points[i], 11, Paint()..color = const Color(0x330B1033));
      canvas.drawCircle(points[i], 10, Paint()..color = Colors.white);
      canvas.drawCircle(points[i], 10, stroke..strokeWidth = 3);
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) => true;
}
