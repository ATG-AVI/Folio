import 'package:flutter/services.dart';

import 'ocr.dart' show OcrLine;

enum ScanError { unavailable, denied, failed }

class ScanException implements Exception {
  const ScanException(this.error);
  final ScanError error;
}

/// Our thin bridge to ML Kit (Android) and VisionKit/Vision (iOS). See plan §6.
abstract final class Native {
  static const _ch = MethodChannel('folio/native');

  /// JPEG paths in the inbox. Empty list = user cancelled.
  static Future<List<String>> scan({int? pageLimit}) async {
    try {
      return await _ch.invokeListMethod<String>('scan', {'pageLimit': pageLimit}) ?? const [];
    } on MissingPluginException {
      throw const ScanException(ScanError.unavailable);
    } on PlatformException catch (e) {
      throw ScanException(ScanError.values.asNameMap()[e.code] ?? ScanError.failed);
    }
  }

  /// TL, TR, BR, BL normalised x,y pairs, or null when no document edges were found (always on Android).
  static Future<List<double>?> detectCorners(String path) async {
    try {
      return await _ch.invokeListMethod<double>('detectCorners', {'path': path});
    } on Exception {
      return null; // No detector (Android, simulator) or it failed: the user drags corners instead.
    }
  }

  /// The text of a page's rendered JPEG, one entry per line in reading order. [] = none found; null = no recogniser
  /// right now (`unavailable`: no Play services, or the model is still downloading) or it failed. Never logs the text.
  static Future<List<OcrLine>?> recognizeText(String path) async {
    try {
      final lines = await _ch.invokeListMethod<Map<dynamic, dynamic>>('recognizeText', {'path': path});
      return [for (final m in lines ?? const <Map<dynamic, dynamic>>[]) OcrLine.fromMap(m)];
    } catch (_) {
      return null; // PlatformException, a missing handler or a malformed reply: all "no text" to the callers
    }
  }

  /// Android: a scan finished while no [scan] was waiting (the activity was recreated), and its pages
  /// are now in the inbox. [recover] runs before native gets its reply; a failure only goes back to native.
  static void onInboxReady(Future<void> Function() recover) => _ch.setMethodCallHandler((call) async {
    if (call.method == 'inboxReady') await recover();
  });

  /// Lets the user pick where the finished PDF at [path] goes; the picker handles name clashes. True = saved,
  /// false = the user cancelled. Throws PlatformException: `unavailable` (no picker) or `failed` (the write).
  static Future<bool> saveAs(String path, String name) async =>
      await _ch.invokeMethod<bool>('saveAs', {'path': path, 'name': name}) ?? false;

  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // Android needs no camera permission, so there is nothing to open.
    }
  }
}
