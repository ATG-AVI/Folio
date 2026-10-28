import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/capture.dart';
import 'package:folio/library.dart';
import 'package:folio/pdf.dart';
import 'package:folio/render.dart' show PageFilter;
import 'package:integration_test/integration_test.dart';

import '../tool/bench.dart' show photo;

/// M7 stress test (PRD §6 and §8, plan M7 "100-page document"): the real library, render isolates and PDF writer.
/// Only the photo picker is left out; its files are made here and handed to ingest() as capture.dart does.
/// (The 20 × 48 MP memory case is render_bench_test.dart's.)
///   fvm flutter test integration_test/stress_test.dart -d DEVICE        (budget: about 6 minutes)
/// Numbers print as `STRESS: ...` in the log, and land in binding.reportData for `flutter drive`. Debug builds are several
/// times slower than --release, and simulators and emulators run on the Mac's CPU: read the memory numbers, not the times.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object>{};
  void say(String key, Object value) {
    report[key] = value;
    binding.reportData = report;
    debugPrint('STRESS: $key = $value');
  }

  int mb(int bytes) => bytes >> 20;

  testWidgets('100-page document exports', (_) async {
    final dir = Directory.systemTemp.createTempSync('folio_stress100');
    // One source copied 100 times: 100 pages without 100 encodes. In an isolate so this one stays free.
    final source = await Isolate.run(() => photo(2400, 1800));
    say('100p source JPEG KB (one source, copied 100 times)', source.length >> 10);
    final inputs = [for (var i = 0; i < 100; i++) (File('${dir.path}/in$i.jpg')..writeAsBytesSync(source)).path];
    final library = await Library.open('${dir.path}/library');
    addTearDown(() async {
      await library.flush();
      dir.deleteSync(recursive: true);
    });
    final start = ProcessInfo.currentRss;

    final (ingested, ingestMs, _) = await _measure(() => ingest(library, inputs, filter: PageFilter.enhance));
    // New documents are Standard quality. Renders already began when ingest saved; renderIdle waits for the rest.
    final (_, renderMs, renderPeak) = await _measure(() => library.renderIdle().timeout(_renderLimit));
    final d = library.byId(ingested.doc!.id)!;
    final (bytes, pdfMs, pdfPeak) = await _measure(() => buildPdf(d));
    final maxRss = ProcessInfo.maxRss;

    final kbPerPage = bytes.length / 100 / 1024;
    say('100p ingest ms', ingestMs);
    say('100p render ms (Standard, after ingest returned)', renderMs);
    say('100p buildPdf ms', pdfMs);
    say('100p PDF MB', (bytes.length / 1024 / 1024).toStringAsFixed(1));
    say('100p PDF KB per page (photo sources, not the §8.5 text-page check)', kbPerPage.toStringAsFixed(0));
    say(
      '100p RSS MB: start / peak renders / peak buildPdf / process max',
      '${mb(start)} / ${mb(renderPeak)} / ${mb(pdfPeak)} / ${mb(maxRss)}',
    );

    expect(ingested.failed, 0);
    expect(d.pages, hasLength(100));
    expect(d.pages.every(d.isRendered), isTrue);
    final text = latin1.decode(bytes);
    expect(text, startsWith('%PDF-'));
    expect(RegExp(r'/Type\s*/Page(?![a-z])').allMatches(text), hasLength(100));
    expect(RegExp(r'/Subtype\s*/Image').allMatches(text), hasLength(100));
    // Loose on purpose: noisy photo sources are heavier than the text pages the 400 KB target is about.
    expect(kbPerPage, lessThan(1500));
  }, timeout: const Timeout(Duration(minutes: 8)));
}

const _renderLimit = Duration(minutes: 4);

/// Runs [body] while sampling resident memory every 20 ms. Returns its result, the elapsed ms and the peak RSS seen.
/// (ProcessInfo.maxRss can't say which phase caused the peak; the isolates are in this process, so RSS covers them.)
Future<(T, int, int)> _measure<T>(Future<T> Function() body) async {
  var peak = ProcessInfo.currentRss;
  final poll = Timer.periodic(const Duration(milliseconds: 20), (_) => peak = max(peak, ProcessInfo.currentRss));
  final sw = Stopwatch()..start();
  try {
    final r = await body();
    return (r, sw.elapsedMilliseconds, peak);
  } finally {
    poll.cancel();
  }
}
