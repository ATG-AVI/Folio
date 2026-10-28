import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folio/native.dart';
import 'package:folio/ocr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('folio/native');
  final asked = <String>[]; // the paths native was given

  /// Stands in for the native side of the channel until the test ends.
  void native(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (c) {
      if (c.method == 'recognizeText') asked.add((c.arguments as Map)['path'] as String);
      return handler(c);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  setUp(() {
    clearTextCache();
    asked.clear();
  });

  const reply = [
    {
      'text': 'FOLIO SEARCH',
      'box': [0.1, 0.2, 0.6, 0.25],
    },
    {
      'text': 'Second line',
      'box': [0, 0.3, 1, 0.35], // ints: a platform may send whole numbers
    },
  ];

  test('OcrLine.fromMap reads the text and a normalised box (left, top, right, bottom)', () {
    final line = OcrLine.fromMap(reply.first);
    expect(line.text, 'FOLIO SEARCH');
    expect(line.box, const Rect.fromLTRB(0.1, 0.2, 0.6, 0.25));
    expect(OcrLine.fromMap(reply.last).box, const Rect.fromLTRB(0, 0.3, 1, 0.35));
  });

  test('OcrLine.fromMap throws on a malformed entry', () {
    for (final m in <Map<String, Object?>>[
      {'text': 'x'},
      {
        'box': [0, 0, 1, 1],
      },
      {
        'text': 'x',
        'box': [0, 0, 1],
      },
      {
        'text': 'x',
        'box': ['a', 'b', 'c', 'd'],
      },
      {
        'text': 3,
        'box': [0, 0, 1, 1],
      },
    ]) {
      expect(() => OcrLine.fromMap(m), throwsA(anything), reason: '$m');
    }
  });

  test('recognizeText sends the path and returns the lines in the order native gave them', () async {
    native((_) async => reply);
    final lines = (await Native.recognizeText('/doc/cache/a.jpg'))!;
    expect(asked, ['/doc/cache/a.jpg']);
    expect([for (final l in lines) l.text], ['FOLIO SEARCH', 'Second line']);
    expect(lines.first.box, const Rect.fromLTRB(0.1, 0.2, 0.6, 0.25));
  });

  test('recognizeText returns [] when there is no text, and null when native has none to give', () async {
    native((_) async => <Object?>[]);
    expect(await Native.recognizeText('/a.jpg'), isEmpty);
    native((_) async => null);
    expect(await Native.recognizeText('/a.jpg'), isEmpty, reason: 'a null reply is no lines, not a failure');
  });

  test('recognizeText: unavailable, failed, any other code, a malformed reply and no native side are all null', () async {
    for (final code in ['unavailable', 'failed', 'anything else']) {
      native((_) async => throw PlatformException(code: code, message: 'secret text must not leak'));
      expect(await Native.recognizeText('/a.jpg'), isNull, reason: code);
    }
    native(
      (_) async => [
        {'text': 'x', 'box': 'nope'},
      ],
    );
    expect(await Native.recognizeText('/a.jpg'), isNull, reason: 'malformed');
    messenger.setMockMethodCallHandler(channel, null);
    expect(await Native.recognizeText('/a.jpg'), isNull, reason: 'no native side');
  });

  test('readText asks native once per path, [] included, and never remembers a failure', () async {
    native((c) async => (c.arguments as Map)['path'] == '/blank.jpg' ? <Object?>[] : reply);
    expect(await readText('/a.jpg'), hasLength(2));
    expect(await readText('/a.jpg'), hasLength(2));
    expect(await readText('/blank.jpg'), isEmpty);
    expect(await readText('/blank.jpg'), isEmpty);
    expect(asked, ['/a.jpg', '/blank.jpg']);

    var down = true; // e.g. the model is still downloading
    native((_) async => down ? throw PlatformException(code: 'unavailable') : reply);
    expect(await readText('/b.jpg'), isNull);
    expect(await readText('/b.jpg'), isNull);
    down = false;
    expect(await readText('/b.jpg'), hasLength(2), reason: 'the failure was not cached');
    expect(asked.where((p) => p == '/b.jpg'), hasLength(3));
  });

  test('readText puts a row’s lines left to right even when a later one is a hair higher, and rows top to bottom', () async {
    Map<String, Object> line(String text, double l, double t, double r, double b) => {
      'text': text,
      'box': [l, t, r, b],
    };
    native(
      (_) async => [
        line('Total', 0.1, 0.502, 0.3, 0.55), // the label, and the amount 0.01 higher on the same row
        line('Date', 0.1, 0.1, 0.3, 0.15),
        line('42.00', 0.7, 0.492, 0.9, 0.54),
        line('Thanks', 0.1, 0.6, 0.5, 0.65), // below the row's centre: a row of its own
      ],
    );
    expect([for (final l in (await readText('/a.jpg'))!) l.text], ['Date', 'Total', '42.00', 'Thanks']);
    expect(
      [for (final l in (await readText('/a.jpg'))!) l.text],
      ['Date', 'Total', '42.00', 'Thanks'],
      reason: 'the cached lines are in order too',
    );
    expect(asked, hasLength(1));
  });

  test('readText: reads of one page in flight share one native call, and a failed one is retried next time', () async {
    final answer = Completer<Object?>();
    native((_) => answer.future);
    final both = Future.wait([readText('/a.jpg'), readText('/a.jpg')]);
    await Future<void>.delayed(Duration.zero);
    answer.complete(reply);
    expect([for (final r in await both) r!.length], [2, 2]);
    expect(asked, ['/a.jpg']);

    final fail = Completer<Object?>();
    native((_) => fail.future);
    final failed = Future.wait([readText('/b.jpg'), readText('/b.jpg')]);
    await Future<void>.delayed(Duration.zero);
    fail.completeError(PlatformException(code: 'unavailable'));
    expect(await failed, [null, null]);
    expect(asked.where((p) => p == '/b.jpg'), hasLength(1));

    native((_) async => reply);
    expect(await readText('/b.jpg'), hasLength(2), reason: 'the failure left nothing behind');
    expect(asked.where((p) => p == '/b.jpg'), hasLength(2));
  });
}
