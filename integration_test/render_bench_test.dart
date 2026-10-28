import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/library.dart';
import 'package:integration_test/integration_test.dart';

import '../tool/bench.dart';

/// The M3a render benchmark on a device. Use a release build on a real low-end phone for numbers
/// that mean anything (emulators and simulators run on the Mac's CPU):
/// fvm flutter drive --release --driver=test_driver/integration_test.dart --target=integration_test/render_bench_test.dart -d DEVICE
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('render benchmark', (tester) async {
    final dir = Directory.systemTemp.createTempSync('folio_bench');
    final results = runBench(dir.path, log: (line) => debugPrint('BENCH $line'));
    binding.reportData = results;
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Plan M3a acceptance: 20 × 48 MP photos through the real import + render path without running out of memory.
  testWidgets('20 × 48 MP photos import and render within memory', (tester) async {
    final dir = Directory.systemTemp.createTempSync('folio_mem');
    final big = File('${dir.path}/p.jpg')..writeAsBytesSync(photo(8000, 6000));
    final inputs = [for (var i = 0; i < 20; i++) big.copySync('${dir.path}/in$i.jpg').path];
    final sw = Stopwatch()..start();
    final library = await Library.open('${dir.path}/lib');
    final doc = (await ingest(library, inputs)).doc!;
    // Tight crops on every 4th page force a full-size decode: the worst case for memory.
    var d = library.byId(doc.id)!;
    for (var i = 0; i < 20; i += 4) {
      d = d.updatePage(i, d.pages[i].copyWith(corners: const [0.4, 0.4, 0.6, 0.4, 0.6, 0.6, 0.4, 0.6]));
    }
    library.save(d);
    final base = ProcessInfo.currentRss;
    var peak = base;
    final poll = Timer.periodic(const Duration(milliseconds: 20), (_) => peak = max(peak, ProcessInfo.currentRss));
    await library.renderIdle();
    poll.cancel();
    final rendered = library.byId(doc.id)!;
    expect(rendered.pages, hasLength(20));
    expect(rendered.pages.every(rendered.isRendered), isTrue);
    binding.reportData = {
      '20x48MP import+render total ms': sw.elapsedMilliseconds,
      'RSS before renders MB': base >> 20,
      'RSS peak during renders MB': peak >> 20,
    };
    debugPrint('BENCH ${binding.reportData}');
    await library.flush();
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

void debugPrint(String s) => stdout.writeln(s);
