// M3a performance spike: time the real render pipeline on realistic page sizes (plan §11, risk 1).
//
// Mac (AOT, like a release build):  fvm dart compile exe tool/bench.dart -o build/bench && build/bench
// Phone (release):  fvm flutter drive --release --driver=test_driver/integration_test.dart \
//                     --target=integration_test/render_bench_test.dart -d DEVICE
import 'dart:io';
import 'dart:math';

import 'package:folio/render.dart';
import 'package:image/image.dart' as img;

/// A photographed page: paper on a darker desk, rows of "text". Busy enough that JPEG sizes are realistic.
List<int> photo(int w, int h) {
  final im = img.Image(width: w, height: h)..clear(img.ColorRgb8(92, 70, 52));
  final pw = w * 3 ~/ 4, ph = h * 5 ~/ 6, px = (w - pw) ~/ 2, py = (h - ph) ~/ 2;
  img.fillRect(im, x1: px, y1: py, x2: px + pw, y2: py + ph, color: img.ColorRgb8(236, 234, 228));
  final line = h ~/ 90;
  for (var y = py + line * 3; y < py + ph - line * 3; y += line * 2) {
    for (var x = px + line * 3; x < px + pw - line * 6; x += line * 5) {
      img.fillRect(im, x1: x, y1: y, x2: x + line * 4, y2: y + line ~/ 2, color: img.ColorRgb8(40, 40, 48));
    }
  }
  // Sensor-like noise: real photos carry it, and JPEG decode time grows with the entropy it adds.
  final rng = Random(1);
  for (final p in im) {
    final n = rng.nextInt(13) - 6;
    p
      ..r = (p.r + n).clamp(0, 255)
      ..g = (p.g + n).clamp(0, 255)
      ..b = (p.b + n).clamp(0, 255);
  }
  return img.encodeJpg(im, quality: 95); // what the import picker hands us (plan §7.1)
}

/// Median wall time of [runs] runs, in ms.
int time(void Function() body, {int runs = 3}) {
  final ms = <int>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    body();
    ms.add(sw.elapsedMilliseconds);
  }
  return (ms..sort())[runs ~/ 2];
}

/// Returns case → milliseconds per page (median). Memory is measured separately (render_bench_test).
Map<String, int> runBench(String dir, {void Function(String)? log}) {
  final results = <String, int>{};
  void record(String name, int ms) {
    results[name] = ms;
    log?.call('$name: $ms ms');
  }

  final scan = '$dir/scan.jpg', p12 = '$dir/p12.jpg', p48 = '$dir/p48.jpg';
  File(scan).writeAsBytesSync(photo(2480, 3508)); // a scanner-sized A4 page, ~8.7 MP
  File(p12).writeAsBytesSync(photo(4000, 3000)); // a 12 MP phone photo
  File(p48).writeAsBytesSync(photo(8000, 6000)); // a 48 MP phone photo
  const tilt = [0.14, 0.09, 0.86, 0.11, 0.88, 0.93, 0.12, 0.91]; // a page photographed at an angle
  void render(String src, {List<double>? corners, PageFilter filter = PageFilter.original, int maxEdge = 2200, int q = 75}) =>
      renderSync((src: src, out: '$dir/out.jpg', corners: corners, turns: 0, filter: filter, maxEdge: maxEdge, quality: q));

  record('ingest 12MP JPEG (copy + header)', time(() => normalizeSync(p12, '$dir/n.jpg')));
  record('scanner page, Standard', time(() => render(scan)));
  record('12MP import, perspective, Standard', time(() => render(p12, corners: tilt)));
  record('12MP import, perspective, B&W', time(() => render(p12, corners: tilt, filter: PageFilter.bw)));
  record('12MP import, perspective, High', time(() => render(p12, corners: tilt, maxEdge: 3000, q: 85)));
  record('12MP import, Enhance, Small', time(() => render(p12, corners: tilt, filter: PageFilter.enhance, maxEdge: 1600, q: 60)));
  record('48MP photo, perspective, Standard', time(() => render(p48, corners: tilt), runs: 1));
  record('ID card side (1100 px)', time(() => render(p12, corners: tilt, maxEdge: 1100)));
  return results;
}

void main() {
  final dir = Directory.systemTemp.createTempSync('folio_bench');
  try {
    runBench(dir.path, log: print);
  } finally {
    dir.deleteSync(recursive: true);
  }
}
