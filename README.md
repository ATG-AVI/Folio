# Folio

A private, on-device document scanner for Android and iOS, built with Flutter. Folio turns paper into clean multi-page PDFs that you can save, share or print. There is no account, and nothing is uploaded.

## Features

- **Scanning** with the operating system's own document scanner: Google ML Kit Document Scanner on Android and VisionKit on iOS. Import photos or take a photo when the scanner isn't available.
- **Editing:** crop with corner handles (with automatic corner detection on iOS), rotate, apply Original / Enhance / Grayscale / B&W filters, reorder, duplicate, replace, retake and delete pages, with undo.
- **ID cards:** a guided front-and-back flow, with both sides printed on one A4 or Letter page at real card size.
- **PDF export:** Fit, A4 or Letter pages; Small, Standard or High quality; Save to device, Share or Print. Page images are embedded as JPEG without re-encoding.
- **Text recognition** (ML Kit on Android, Vision on iOS): Copy text from a page, and an optional searchable PDF with an invisible text layer.
- **Library:** documents are saved on the device as you work, with search, sort, rename, duplicate and delete. Scans interrupted by the system are recovered.
- **Accessibility:** screen-reader labels and actions, 200 % text, light and dark themes, edge-to-edge layout.

## Requirements

- Flutter 3.47.8, pinned with [FVM](https://fvm.app) (`.fvmrc`)
- Android 7.0+ (API 24). The scanner needs Google Play services and falls back to photos without it.
- iOS 15+

## Build and run

```bash
fvm install
fvm flutter pub get
fvm flutter run
```

Release builds:

```bash
fvm flutter build apk --release
fvm flutter build ios --release
```

Android release builds are signed with the debug key until a release keystore is configured.

## Tests

```bash
fvm flutter analyze
fvm flutter test
fvm flutter test integration_test/editor_test.dart -d <device>
```

The integration tests in `integration_test/` run on a simulator or emulator. `integration_test/screenshots_test.dart` produces design-review screenshots through `flutter drive` (see the file's header).

## Project layout

- `lib/`: the app (library and storage, render pipeline, PDF builder, screens)
- `android/app/src/main/kotlin/…/MainActivity.kt`: ML Kit scanner, text recognition and Save as
- `ios/Runner/AppDelegate.swift`: VisionKit scanner, Vision corner and text detection, and the Files export picker
- `docs/PRD.md`: product requirements
- `docs/IMPLEMENTATION_PLAN.md`: architecture, decisions and the milestone log
