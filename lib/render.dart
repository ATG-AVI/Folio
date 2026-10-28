/// Pure-Dart image work: no Flutter, no dart:ui, so it runs in a background isolate (and in the
/// command-line benchmark, tool/bench.dart). Plan §7.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

enum PageFilter {
  original('Original'),
  enhance('Enhance'),
  grayscale('Grayscale'),
  bw('B&W');

  const PageFilter(this.label);
  final String label;
}

/// Projective map of the unit square onto quad q (TL, TR, BR, BL as x,y pairs).
/// Returns [a, b, c, d, e, f, g, h]: x = (a·u + b·v + c) / (g·u + h·v + 1), y = (d·u + e·v + f) / (…).
/// Heckbert, "Fundamentals of Texture Mapping", 1989.
List<double> squareToQuad(List<double> q) {
  final [x0, y0, x1, y1, x2, y2, x3, y3] = q;
  final dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
  final dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  final den = dx1 * dy2 - dx2 * dy1;
  final g = (dx3 * dy2 - dx2 * dy3) / den;
  final h = (dx1 * dy3 - dx3 * dy1) / den;
  return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h];
}

/// True when TL, TR, BR, BL form a convex quad that runs clockwise on screen (y down). Counter-clockwise
/// means handles were dragged past each other: still convex, but it would render a mirror image.
bool isConvex(List<double> q) {
  for (var i = 0; i < 4; i++) {
    final a = i * 2, b = (i + 1) % 4 * 2, c = (i + 2) % 4 * 2;
    final z = (q[b] - q[a]) * (q[c + 1] - q[b + 1]) - (q[b + 1] - q[a + 1]) * (q[c] - q[b]);
    if (z < 1e-9) return false;
  }
  return true;
}

/// 4×5 colour matrices (Flutter ColorFilter.matrix layout, offsets in 0..255). The render applies the
/// same matrices, so the GPU preview and the file agree. B&W is a contrast preview here; the render
/// uses the grayscale matrix and then an adaptive threshold.
List<double> previewMatrix(PageFilter filter) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  List<double> gray(double k, double o) => [
    for (var i = 0; i < 3; i++) ...[r * k, g * k, b * k, 0, o],
    0,
    0,
    0,
    1,
    0,
  ];
  return switch (filter) {
    PageFilter.enhance => [1.18, 0, 0, 0, -12, 0, 1.18, 0, 0, -12, 0, 0, 1.18, 0, -12, 0, 0, 0, 1, 0],
    PageFilter.grayscale => gray(1, 0),
    PageFilter.bw => gray(3.2, -300),
    PageFilter.original => [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
  };
}

/// Stable 64-bit hash as 16 hex chars (two FNV-1a 32 passes): same input, same name, on every run.
String stableHash(String s) {
  int fnv(int seed) {
    var h = seed;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 16777619) & 0xFFFFFFFF;
    }
    return h;
  }

  return fnv(0x811C9DC5).toRadixString(16).padLeft(8, '0') + fnv(0x01000193).toRadixString(16).padLeft(8, '0');
}

/// Everything one render depends on. Plain values, so it can cross into an isolate.
typedef RenderSpec = ({String src, String out, List<double>? corners, int turns, PageFilter filter, int maxEdge, int quality});

/// Renders one page: perspective crop, rotation, filter, then an EXIF-free JPEG at [RenderSpec.out]
/// (written to a temp file, synced, renamed). Returns the output size. Run it with Isolate.run.
(int, int) renderSync(RenderSpec s) {
  final bytes = File(s.src).readAsBytesSync();
  final (fullW, fullH) = uprightSize(bytes);
  final q = s.corners ?? const [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0];
  double edge(int a, int b) => sqrt(pow((q[a * 2] - q[b * 2]) * fullW, 2) + pow((q[a * 2 + 1] - q[b * 2 + 1]) * fullH, 2));
  final quadW = max(edge(0, 1), edge(3, 2)), quadH = max(edge(0, 3), edge(1, 2));
  final k = min(1.0, s.maxEdge / max(quadW, quadH)); // never upscale
  final w = max(1, (quadW * k).round()), h = max(1, (quadH * k).round());

  // Decode no bigger than needed: JPEG can shrink 2/4/8× while decoding (faster, far less memory),
  // while keeping the source ≤ 2× the output so bilinear sampling doesn't alias thin text.
  final shrink = 1 / k / 2;
  final src = _decode(bytes, shrink >= 4 ? 8 : (shrink >= 2 ? 4 : (shrink >= 1 ? 2 : 1)));
  final sw = src.width, sh = src.height;
  final px = src.getBytes(order: img.ChannelOrder.rgb);
  final [a, b, c, d, e, f, g, hh] = squareToQuad([for (var i = 0; i < 8; i++) q[i] * (i.isEven ? sw : sh)]);

  final odd = s.turns.isOdd;
  final rw = odd ? h : w, rh = odd ? w : h;
  // Output pixel centre (ox, oy in 0..1) → unrotated crop position: u = uX·ox + uY·oy + u0, same for v.
  // Rotation is clockwise, matching RotatedBox in the preview.
  final (uX, uY, u0, vX, vY, v0) = switch (s.turns) {
    1 => (0.0, 1.0, 0.0, -1.0, 0.0, 1.0),
    2 => (-1.0, 0.0, 1.0, 0.0, -1.0, 1.0),
    3 => (0.0, -1.0, 1.0, 1.0, 0.0, 0.0),
    _ => (1.0, 0.0, 0.0, 0.0, 1.0, 0.0),
  };
  final m = previewMatrix(s.filter == PageFilter.bw ? PageFilter.grayscale : s.filter);
  final [m0, m1, m2, _, m4, m5, m6, m7, _, m9, m10, m11, m12, _, m14, ...] = m;
  int byte(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : (v + 0.5).toInt());
  final out = Uint8List(rw * rh * 3);
  var o = 0;
  for (var y = 0; y < rh; y++) {
    final oy = (y + 0.5) / rh;
    for (var x = 0; x < rw; x++) {
      final ox = (x + 0.5) / rw;
      final u = uX * ox + uY * oy + u0, v = vX * ox + vY * oy + v0;
      final z = g * u + hh * v + 1;
      final sx = (a * u + b * v + c) / z - 0.5, sy = (d * u + e * v + f) / z - 0.5;
      // Bilinear sample, clamped to the image.
      final x0 = sx <= 0 ? 0 : min(sx.floor(), sw - 1), y0 = sy <= 0 ? 0 : min(sy.floor(), sh - 1);
      final x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1);
      // At the far edge x1 == x0, so any weight is fine; only the near edge needs clamping.
      final fx = sx <= 0 ? 0.0 : sx - x0, fy = sy <= 0 ? 0.0 : sy - y0;
      final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy;
      final i00 = (y0 * sw + x0) * 3, i10 = (y0 * sw + x1) * 3, i01 = (y1 * sw + x0) * 3, i11 = (y1 * sw + x1) * 3;
      final r = px[i00] * w00 + px[i10] * w10 + px[i01] * w01 + px[i11] * w11;
      final gr = px[i00 + 1] * w00 + px[i10 + 1] * w10 + px[i01 + 1] * w01 + px[i11 + 1] * w11;
      final bl = px[i00 + 2] * w00 + px[i10 + 2] * w10 + px[i01 + 2] * w01 + px[i11 + 2] * w11;
      out[o++] = byte(m0 * r + m1 * gr + m2 * bl + m4);
      out[o++] = byte(m5 * r + m6 * gr + m7 * bl + m9);
      out[o++] = byte(m10 * r + m11 * gr + m12 * bl + m14);
    }
  }
  if (s.filter == PageFilter.bw) _threshold(out, rw, rh);

  final jpeg = img.encodeJpg(
    img.Image.fromBytes(width: rw, height: rh, bytes: out.buffer, numChannels: 3), // fresh image: no EXIF/GPS
    quality: s.quality,
    chroma: img.JpegChroma.yuv420,
  );
  writeDurably(s.out, jpeg);
  return (rw, rh);
}

/// Copies an input image to [to] as a JPEG and returns its upright size; throws if it isn't an image.
/// JPEGs are copied byte for byte (every decoder honours their EXIF orientation). Anything else
/// (PNG screenshots, WebP…) is decoded, flattened onto white and re-encoded at quality 92.
(int, int) normalizeSync(String from, String to) {
  final bytes = File(from).readAsBytesSync();
  if (img.JpegDecoder().isValidFile(bytes)) {
    final size = uprightSize(bytes);
    writeDurably(to, bytes);
    return size;
  }
  // Pure-Dart decode costs ~10 bytes per pixel: refuse absurd sizes (a 1 MB PNG can claim 268 MP)
  // rather than be killed for memory. Real screenshots and photos are far below this.
  final limit = img.Decoder.defaultMaxPixels; // a global: restore it so other decodes keep their limit
  img.Decoder.defaultMaxPixels = 24 * 1000 * 1000;
  final img.Image image;
  try {
    image = img.decodeImage(bytes, frame: 0) ?? (throw const FormatException('Not a supported image'));
  } finally {
    img.Decoder.defaultMaxPixels = limit;
  }
  final rgba = image.convert(format: img.Format.uint8, numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  final rgb = Uint8List(image.width * image.height * 3);
  for (var i = 0, o = 0; i < rgba.length; i += 4, o += 3) {
    final alpha = rgba[i + 3];
    for (var ch = 0; ch < 3; ch++) {
      rgb[o + ch] = (rgba[i + ch] * alpha + 255 * (255 - alpha)) ~/ 255;
    }
  }
  final jpeg = img.encodeJpg(
    img.Image.fromBytes(width: image.width, height: image.height, bytes: rgb.buffer, numChannels: 3),
    quality: 92,
    chroma: img.JpegChroma.yuv420,
  );
  writeDurably(to, jpeg);
  return (image.width, image.height);
}

/// Width and height as displayed: JPEG from its header and EXIF orientation (no pixel decode).
(int, int) uprightSize(Uint8List bytes) {
  final jpeg = img.JpegDecoder();
  if (jpeg.isValidFile(bytes)) {
    final info = jpeg.startDecode(bytes) ?? (throw const FormatException('Bad JPEG'));
    final o = img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1;
    return o >= 5 && o <= 8 ? (info.height, info.width) : (info.width, info.height);
  }
  final image = img.decodeImage(bytes) ?? (throw const FormatException('Not a supported image'));
  return (image.width, image.height);
}

/// Writes via a temp file + fsync + rename: readers see the old file or the whole new one.
void writeDurably(String path, List<int> bytes) {
  final tmp = File('$path.tmp');
  final f = tmp.openSync(mode: FileMode.write);
  try {
    f
      ..writeFromSync(bytes)
      ..flushSync();
  } finally {
    f.closeSync();
  }
  tmp.renameSync(path);
}

img.Image _decode(Uint8List bytes, int scale) {
  if (img.JpegDecoder().isValidFile(bytes)) return img.JpegDecoder(scale: scale).decode(bytes)!;
  return img.decodeImage(bytes) ?? (throw const FormatException('Not a supported image'));
}

/// Bradley–Roth adaptive threshold, in place on gray RGB: a pixel is ink when it is 15% darker than
/// the mean of its (width/8)-wide neighbourhood. Copes with shadows and uneven light, unlike a fixed cut.
void _threshold(Uint8List rgb, int w, int h) {
  final ii = Uint32List((w + 1) * (h + 1)); // integral image; fits 32 bits up to ~16 MP
  for (var y = 0; y < h; y++) {
    var row = 0;
    for (var x = 0; x < w; x++) {
      row += rgb[(y * w + x) * 3];
      ii[(y + 1) * (w + 1) + x + 1] = ii[y * (w + 1) + x + 1] + row;
    }
  }
  final r = max(4, w ~/ 16);
  for (var y = 0; y < h; y++) {
    final y0 = max(0, y - r), y1 = min(h, y + r + 1);
    for (var x = 0; x < w; x++) {
      final x0 = max(0, x - r), x1 = min(w, x + r + 1);
      final sum = ii[y1 * (w + 1) + x1] - ii[y0 * (w + 1) + x1] - ii[y1 * (w + 1) + x0] + ii[y0 * (w + 1) + x0];
      final o = (y * w + x) * 3;
      final v = rgb[o] * (x1 - x0) * (y1 - y0) * 100 <= sum * 85 ? 0 : 255;
      rgb[o] = rgb[o + 1] = rgb[o + 2] = v;
    }
  }
}
