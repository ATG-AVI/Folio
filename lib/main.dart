import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

import 'capture.dart';
import 'home_screen.dart';
import 'library.dart';
import 'licenses.dart';
import 'native.dart';

final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Startup order matters (plan §5): load, then recover the inbox, then wipe temp.
Future<void> main() async {
  final launch = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  registerLicenses();
  // The Photo Picker (no permission, multi-select grid) on Android 7–15 too, not the Files-style picker.
  final picker = ImagePickerPlatform.instance;
  if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
  final support = (await getApplicationSupportDirectory()).path;
  final library = await Library.open(
    '$support/library',
    onError: (_) => messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Couldn’t save a change on this phone. Check that there’s free storage.')),
    ),
  );
  // Before the startup pass: a result landing meanwhile is seen by that pass or by this handler.
  final inbox = '$support/inbox';
  Native.onInboxReady(() => recoverInbox(library, inbox));
  // Never block launch on recovery: whatever stays in the inbox is retried next time.
  await recoverInbox(library, inbox).catchError((Object _) {});
  if (Platform.isAndroid) await recoverLostPicks(library).catchError((Object _) {});
  final temp = (await getTemporaryDirectory()).path;
  await wipeTemp(temp, iosTmp: Platform.isIOS ? Directory.systemTemp.path : null).catchError((Object _) {});
  if (Platform.isAndroid) {
    androidPickerSweep = (dir: temp, launch: launch); // runs before the first pick (see capture.dart)
  } else {
    await clearPickerCopies(Directory.systemTemp.path, android: false, launch: launch).catchError((Object _) {});
  }
  runApp(FolioApp(library: library));
}

/// Exports and staging live in `<temp>/folio`; nothing there outlives a launch. So do printing's share copies:
/// `<temp>/share` (Android cache) and, on iOS, the `*.pdf` files in [iosTmp] (NSTemporaryDirectory, which
/// getTemporaryDirectory is not).
Future<void> wipeTemp(String temp, {String? iosTmp}) async {
  for (final dir in [Directory('$temp/folio'), Directory('$temp/share')]) {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
  if (iosTmp != null && await Directory(iosTmp).exists()) {
    await for (final e in Directory(iosTmp).list()) {
      if (e is File && e.path.endsWith('.pdf')) await e.delete();
    }
  }
}

class FolioApp extends StatelessWidget {
  const FolioApp({super.key, required this.library});

  final Library library;

  @override
  Widget build(BuildContext context) => LibraryScope(
    notifier: library,
    child: MaterialApp(
      title: 'Folio',
      scaffoldMessengerKey: messengerKey,
      debugShowCheckedModeBanner: false,
      theme: folioTheme(Brightness.light),
      darkTheme: folioTheme(Brightness.dark),
      // Behind the whole app, so it reaches the bottom of the screen, where Android reads the navigation bar's style.
      builder: (context, child) => AnnotatedRegion(value: systemBars(Theme.of(context).brightness), child: child!),
      home: const HomeScreen(),
    ),
  );
}

/// Edge to edge (Android 15+ draws every app that way; Android 16 has no opt-out): bars transparent, Android's own
/// scrim left behind the 3-button bar (status bar: none), and icons that contrast with the page. [SystemUiOverlayStyle.light] and `.dark`
/// both leave the navigation bar black with light icons, so the style is spelled out.
SystemUiOverlayStyle systemBars(Brightness page) {
  final icons = page == Brightness.light ? Brightness.dark : Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: page, // iOS names the bar's background, not its icons
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    // systemNavigationBarContrastEnforced stays null: Android keeps its scrim behind the 3-button bar, so dark-mode
    // icons stay readable over white page thumbnails scrolling under it (false removes the scrim).
  );
}

const _ultramarine = Color(0xFF2C46E0);

ThemeData folioTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  Color c(int l, int d) => Color(light ? l : d);
  final scheme = ColorScheme.fromSeed(seedColor: _ultramarine, brightness: brightness, dynamicSchemeVariant: DynamicSchemeVariant.fidelity)
      .copyWith(
        primary: c(0xFF2C46E0, 0xFF9AA9FF),
        onPrimary: c(0xFFFFFFFF, 0xFF0B1660),
        primaryContainer: c(0xFFE2E6FF, 0xFF27358F),
        onPrimaryContainer: c(0xFF111C6B, 0xFFE2E6FF),
        // Selected segments, tonal buttons: same brand tint as primaryContainer.
        secondaryContainer: c(0xFFE2E6FF, 0xFF27358F),
        onSecondaryContainer: c(0xFF111C6B, 0xFFE2E6FF),
        // Scanner-glass grey desk; paper-white sheets on top.
        surface: c(0xFFF3F4F7, 0xFF14161B),
        surfaceContainerLowest: c(0xFFFFFFFF, 0xFF1B1E24),
        surfaceContainerLow: c(0xFFF8F9FB, 0xFF1D2027),
        surfaceContainer: c(0xFFE9EBF0, 0xFF22252D),
        surfaceContainerHigh: c(0xFFE2E5EB, 0xFF282B34),
        surfaceContainerHighest: c(0xFFDADEE6, 0xFF2F333D),
        onSurface: c(0xFF151A2D, 0xFFE7E9EF),
        onSurfaceVariant: c(0xFF596074, 0xFF9DA3B1),
        outline: c(0xFF8C93A5, 0xFF6C7282),
        outlineVariant: c(0xFFD9DCE3, 0xFF30343E),
      );
  final base = ThemeData(colorScheme: scheme);
  // Material's default tracking (+0.25..0.5) reads loose in SF Pro; flatten it.
  const flat = TextStyle(letterSpacing: 0);
  final t = base.textTheme.merge(
    const TextTheme(
      bodyLarge: flat,
      bodyMedium: flat,
      bodySmall: flat,
      labelLarge: flat,
      labelMedium: flat,
      labelSmall: flat,
      titleMedium: flat,
      titleSmall: flat,
    ),
  );
  const tight = TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.6);
  final pill = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: t.copyWith(
      displaySmall: t.displaySmall!.merge(tight),
      headlineMedium: t.headlineMedium!.merge(tight),
      headlineSmall: t.headlineSmall!.merge(tight),
      // Toolbar titles: compact, like a native nav bar. Home's large title uses headlineMedium.
      titleLarge: t.titleLarge!.copyWith(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: t.titleMedium!.copyWith(fontWeight: FontWeight.w600),
      titleSmall: t.titleSmall!.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
      labelLarge: t.labelLarge!.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      actionsPadding: const EdgeInsets.only(right: 8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
        shape: pill,
        textStyle: WidgetStatePropertyAll(t.labelLarge!.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(0, 52)), shape: pill),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      constraints: const BoxConstraints(minHeight: 48),
      hintStyle: WidgetStatePropertyAll(t.bodyLarge!.copyWith(color: scheme.onSurfaceVariant)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLowest,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      showDragHandle: true,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainerLowest),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
