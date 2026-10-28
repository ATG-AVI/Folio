# Folio: Implementation Plan

> Status: **approved 2026-10-27 (D1–D5 recommended defaults; working name Folio)**. M0–M8 are done; see §14. Store release still needs the items under M7 "Needs you".
> Requirements are in [PRD.md](PRD.md). Package facts were checked against pub.dev, GitHub source and Google/Apple docs on 2026-10-27. A second, independent pass then checked every claim adversarially, and three reviewers checked the plan for coverage, correctness and over-engineering.

---

## 1. Inspection findings

| Item | Finding |
|---|---|
| Existing project | None. No scanner project exists on this Mac, so this is a **fresh app**. The only other Flutter app is ThisKrit (`~/Desktop/Thiskrit`), which must not be disturbed. |
| Flutter | 3.41.8 stable, Dart 3.11.5, global Homebrew install. Latest stable is **3.47.8** (2026-10-23, Dart 3.13.7). |
| Xcode / iOS | Xcode 26.6. Fine for App Store uploads today. |
| Android | SDK 36, NDK 28.2, JDK 17. Some SDK licences are not accepted yet (`flutter doctor --android-licenses`). |
| Consequence | Current `pdf`, `printing`, `flutter_riverpod`, `sqflite` and the `image_picker` platform implementations need Dart ≥ 3.12. On 3.41.8, pub silently resolves older versions. See D2. |

## 2. Architecture decision

**A flat `lib/` with one file per responsibility. Two layers: UI widgets, and plain Dart services. No Clean Architecture ceremony.**

The app has about 7 screens and one data source, the local library. Use cases, repository interfaces and DI containers would add files without adding safety. The separation you asked for (UI, business logic, scanning, image processing, PDF and persistence) lives at file level, as shown in §5. Each service is a concrete class with two test seams: the disk (a temp directory in tests) and one MethodChannel (a mock handler in tests).

| Concern | Choice | Why |
|---|---|---|
| State management | **Plain Flutter.** `Library extends ChangeNotifier` holds the documents. Page operations are pure functions on `Document`. Transient UI state lives in `StatefulWidget`. | This is the least code for one shared model, and plain Dart objects are fully unit-testable. Riverpod 3 would add a dependency plus auto-retry, paused listeners and `ProviderException` semantics that we don't need (D3). |
| Dependency injection | The built-in `InheritedNotifier<Library>` (about 8 lines), plus constructor parameters. | One app-wide model needs no container. Tests build `Library(root: tempDir)`. |
| Navigation | `Navigator.push(MaterialPageRoute)`. | There are no deep links, no web and no nested navigation. Add `go_router` when "Open with Folio" deep links arrive. |
| Scanning engine | **The OS scanners, through our own thin channel:** ML Kit Document Scanner 16.0.0 on Android and VisionKit `VNDocumentCameraViewController` on iOS. | They give the best available edge detection, auto-capture and perspective correction, and on Android they also remove stains and fingers. We maintain zero CV code. Our channel is about 350 native lines, against about 4,000 in the best wrapper package (§4). |
| Corners for imports | iOS uses Vision `VNDetectDocumentSegmentationRequest` (iOS 15+). Android uses full-image corners plus our editor. | Android has no public still-image detector, and we don't want OpenCV. |
| Image pipeline | Pure Dart in a background isolate. The `image` package only decodes images and encodes JPEG; about 120 of our own lines do the homography warp, colour matrix and adaptive threshold. | Output is identical on both platforms. A 12 MP warp measured 115–120 ms on an M4 (desktop AOT); phone timings get a spike in M3a. OpenCV would cost several MB per ABI plus a native build, all for about 60 lines of maths. |
| PDF | `pdf` (low-level API) plus `printing`. | JPEG pass-through (`DCTDecode`, no re-encode) means the PDF size is close to the sum of the page JPEGs. `printing` covers print and share. |
| Storage | **A folder per document plus a `doc.json` manifest**, loaded into memory at startup. Writes are atomic (tmp + rename). | No database and no codegen. Search and sort over fewer than 1,000 documents is instant in memory, and a folder is a natural unit for sync. Upgrade path: a `sqflite` index if we need several thousand documents or OCR full-text search. |
| Errors | `ScanError { unavailable, denied, failed }`, where an empty result `[]` means cancelled. The UI shows a snackbar or a designed state. Atomic writes mean a failure never leaves partial data. | No error framework. Each error is handled where the user can act on it. |
| Permissions | **No `permission_handler`.** ML Kit runs inside Play services and needs no CAMERA permission. VisionKit prompts by itself. The pickers need no permission. The iOS "denied" check and the Settings link take 3 lines of Swift. | One less dependency, and less manifest and plist surface. |
| Theme | SDK Material 3, using `ColorScheme.fromSeed` for light and dark. | Zero dependencies. When SDK Material is formally deprecated, moving to `material_ui` is one `dart fix`. |
| Testing | `flutter_test` with fakes, `integration_test`, and a manual device checklist. | Services touch only the disk (a temp directory in tests) and one MethodChannel (a mock handler), so fakes cover them without a mocking library. `integration_test` drives the real app and produces the design screenshots, replacing golden tests. The OS scanners can't run in CI or on the Simulator, so their behaviour is covered by the device checklist and reported as **unverified** until it has been checked. |

### Approaches considered

| | A. OS scanners + thin channel **(recommended)** | B. `cunning_document_scanner` wrapper | C. `camera` + OpenCV custom scanner |
|---|---|---|---|
| Detection and capture quality | Best (Google and Apple ML) | Same engines | Noticeably worse, and we tune it ourselves |
| Our code | About 350 native lines + a crop view of about 150 lines | About 0 native lines (we still need the crop view) | 1,500+ lines |
| Third-party native code | None | About 4,050 lines, one maintainer | OpenCV (MBs per ABI, CMake build) |
| Custom-branded camera UI | No | No | Yes |
| Control over races, process death and file placement | Full | Limited | Full |

B is a valid drop-in if we would rather not own native code. The Dart API in §6 is shaped so that B could replace A without touching the UI.

## 3. Platform scanners: what we get and what we give up

| | Android ML Kit (FULL mode) | iOS VisionKit |
|---|---|---|
| Live edges, auto-capture, manual shutter | ✅ | ✅ |
| Flash toggle | Shown in the UI, not in the API docs. **Verify on a device (M4).** | ✅ |
| Multi-page capture, corner adjustment and filter review | ✅ | ✅ |
| Gallery import | Only through a button inside the scanner. Auto-crop there is **unverified**. | ❌ |
| Page limit (retake = 1) | ✅ `setPageLimit` | ❌ Swift saves only the first page (no hint: the user sees the result straight away). |
| Returns the original image or the corner points | ❌ Cropped JPEG only | ❌ Cropped image only |
| Themeable UI, camera switching | ❌ | ❌ |
| Requirements | Play services, ≥ 1.7 GB RAM, module downloaded on first use | A real device. Treated as unavailable on the Simulator, on Mac, and when `!isSupported`. |

Consequence: **for scanned pages, the scanner's output becomes the page's original.** Later crops and filters work on that image, which is fine because the scanner has already cropped it well. Pages imported through the picker keep the uncropped photo, so re-cropping them is fully non-destructive.

## 4. Dependencies

### Runtime (7 direct dependencies, 5 of them distinct packages)
| Package | Version | License | Role |
|---|---|---|---|
| `pdf` | 3.13.1 (2026-09-19) | Apache-2.0 | Writes the PDF, embeds JPEGs as-is, supports invisible text (needed later for OCR) |
| `printing` | 5.15.1 (2026-09-19) | Apache-2.0 | `Printing.layoutPdf` (print) and `Printing.sharePdf` (share sheet) |
| `image` | 4.12.0 (2026-10-11) | MIT, plus Apache/BSD notices (register `LICENSE-other.md` with `LicenseRegistry`) | Image decode (applies EXIF orientation) and JPEG encode, run in an isolate |
| `image_picker` | 1.2.4 (2026-10-06) | Apache-2.0 / BSD-3 | Gallery multi-select, and the system camera fallback |
| `image_picker_android`, `image_picker_platform_interface` | (image_picker's own federated packages) | BSD-3 | Declared directly only to set `useAndroidPhotoPicker = true`, so Android 7–15 also get the Photo Picker instead of the document UI |
| `path_provider` | 2.1.6 (2026-06-15) | BSD-3 | App Support and temp directories |

Native dependencies: `com.google.android.gms:play-services-mlkit-document-scanner:16.0.0` (Gradle, about 300 KB, ML Kit Terms). On iOS: VisionKit, Vision, ImageIO and UIKit (system frameworks).

Dev dependencies: `flutter_test` and `integration_test` (SDK), and `flutter_lints`.

Later, for OCR in M8: `com.google.android.gms:play-services-mlkit-text-recognition:19.0.2` (unbundled, about 260 KB), Apple Vision `VNRecognizeTextRequest`, and `NotoSans-Regular.ttf` (OFL, about 430 KB).

### Evaluated and rejected
| Package | Reason |
|---|---|
| `cunning_document_scanner` 3.0.4 | Healthy, but about 4k lines of single-maintainer native code, and its croppers don't match our UI. **Fallback for approach B.** |
| `flutter_doc_scanner` 0.0.21 | Still 0.0.x, uses a legacy Gradle setup, and has no iOS gallery support |
| `google_mlkit_document_scanner` 0.6.1 | Android only, and needs Dart 3.12 |
| `edge_detection` 1.1.3 | Unmaintained since 2023. Has UIScene, 16 KB page-size and edge-to-edge bugs. |
| `document_scanner_flutter`, `flutter_document_scanner`, `doclens`, `document_scan`, etc. | Stale, legacy Gradle, single developer, or AGPL |
| `opencv_dart` / `dartcv4`, `camera` | Only needed for approach C |
| `flutter_image_compress` | Pulls in SDWebImage, libwebp, heifwriter and commons-io. `image_picker` resizing plus our Dart decode is enough. |
| `crop_your_image`, `image_cropper`, perspective-crop packages | Rectangle-only, incompatible with our SDK, or unproven |
| `reorderable_grid` | Pulls in legacy Material. The built-in `ReorderableListView` also gives screen-reader reordering. |
| `share_plus`, `file_picker`, `flutter_file_dialog` | `printing` already shares, and Save-As is about 30 lines of native code |
| `flutter_riverpod` 3.4.3 | **Fallback for D3.** Not needed at this size. |
| `flutter_bloc`, `provider`, `go_router`, `permission_handler`, `app_settings` | The SDK or a few native lines cover them |
| `sqflite` 2.4.5 | Upgrade path for scale or full-text search |
| `drift`, `isar` (abandoned) / `isar_community`, `hive_ce`, `objectbox` | Codegen and/or native binaries for no gain |
| `syncfusion_flutter_pdf` | Proprietary licence with revenue and team-size thresholds |
| `google_mlkit_text_recognition` | About 38 MB per script on iOS, CocoaPods-only shortly before the trunk freeze, no arm64 simulator support, and telemetry |
| `golden_toolkit` / `alchemist` | Discontinued, or not needed: `integration_test` screenshots cover design review |

## 5. Project structure and data

```
folio/
├─ lib/
│  ├─ main.dart            # App + theme, LibraryScope, startup sequence (below)
│  ├─ document.dart        # Document, Page, enums, JSON; pure page ops: add, move, duplicate, remove, replace, update
│  ├─ library.dart         # Library (ChangeNotifier): load/sweep, create, save, rename, duplicate, delete, query, inbox
│  ├─ native.dart          # MethodChannel 'folio/native' (§6)
│  ├─ capture.dart         # scan/import/take-photo → pages: sequential ingest, PNG/HEIC→JPEG, corners, cancel
│  ├─ render.dart          # Pure Dart: homography, colour matrix, Bradley threshold; render() via serial Isolate.run queue
│  ├─ pdf.dart             # layout(doc, opts) → page rects (shared with preview); buildPdf() in Isolate.run
│  ├─ home_screen.dart     # Library list, search, sort, item menu, Scan / Import / ID card entries, empty & damaged states
│  ├─ id_card_sheet.dart   # Front → "flip the card" → back guide; creates an idCard document
│  ├─ pages_screen.dart    # Review Pages: ReorderableListView, add, duplicate, replace, delete+undo, Export
│  ├─ page_screen.dart     # Crop & Enhance pager: filter strip, Apply to all, rotate, crop, retake, delete
│  ├─ crop_view.dart       # 4-corner editor (CustomPainter, drag handles, RawMagnifier, convexity check)
│  ├─ export_sheet.dart    # Name, page size, quality, preview (from layout()), Save / Share / Print, cancel
│  └─ ui.dart              # Shared: PageImage, IconLabelButton, sheetBody, toast, confirm, rename, deletePage+undo
├─ android/app/src/main/kotlin/…/MainActivity.kt   # ML Kit scan, inbox, module prefetch, SAF save
├─ android/app/src/main/res/xml/data_extraction_rules.xml                                  # D4
├─ ios/Runner/AppDelegate.swift                      # VisionKit host, Vision corners, export picker, settings, backup flag
├─ test/                 # unit + widget
├─ integration_test/     # flows + screenshot run
└─ tool/check.sh         # format, analyze, test, debug builds (§9)
```
That is 14 Dart files plus about 350 lines of Kotlin and Swift. The original target was about 1,600 Dart lines. After M1, the UI shell alone is about 2,200 lines as written by `dart format` (tall style, 140 columns), so the revised estimate for the finished app is about 3,000 formatted Dart lines (see §14).

### Storage layout
```
<ApplicationSupport>/library/<docId>/doc.json
<ApplicationSupport>/library/<docId>/src/<srcId>.jpg          # original: scanner output or imported photo
<ApplicationSupport>/library/<docId>/cache/<r>.jpg            # rendered output (r = hash of src + params; equal pages share it)
<ApplicationSupport>/inbox/                                   # scanner results land here first (survives process death)
<Temp>/folio/                                                 # exported PDFs
```
`doc.json`, version 1:
```json
{ "v": 1, "id": "k3f9…", "name": "Scan 2026-10-27 18.40", "kind": "document",
  "createdAt": "2026-10-27T18:40:12Z", "updatedAt": "2026-10-27T18:41:03Z",
  "pageSize": "fit", "quality": "standard",
  "pages": [ { "id": "p1…", "src": "src/a9c2.jpg", "r": "5e0b…",
               "corners": [0.04,0.03, 0.97,0.02, 0.98,0.96, 0.03,0.97], "turns": 1, "filter": "bw" } ] }
```
- **Coordinates and paths.** Corners are normalised to 0..1, start top-left and run clockwise, in upright (post-EXIF) space. Paths are relative, because the iOS container path changes across updates.
- **Atomic writes.** Pages are written first, then `doc.json.tmp`, which is then renamed into place. Duplicating a document builds `<newId>.tmp/` and renames it when done.
- **Deletes and undo.** Deleting a document is confirmed in a dialog, then done with `Directory.delete(recursive: true)`. Deleting or replacing a page only edits `doc.json`; undo puts the `Page` object back. Replace and Retake write to a **new** `srcId`, so cached renders and Flutter's image cache can never show the old image.
- **Load sweep.** `Library.load()` removes `*.tmp` folders, folders with no `doc.json` (a new document whose first save never landed), and any `src/` or `cache/` file that `doc.json` doesn't reference. That covers orphans left by deletes, replaces and crashes. A `doc.json` that won't parse, or that has `v` ≠ 1 (a newer app wrote it), marks the document **damaged**. A damaged document is never saved, swept or deleted automatically.
- **Ingest order.** Copy each input into `src/`, save the manifest, and only then delete the inputs. A crash can therefore at worst bring a scan back twice from the inbox; it can never lose one.
- **Application Support, not Documents**, so the iOS Files app never exposes our internal files.
- **Ready for sync.** IDs are stable, every document has an `updatedAt`, and each document folder is self-contained. Sync would upload `doc.json` and `src/` and skip `cache/`. Only `Library` touches the disk.
- IDs are 16 hex characters from `Random.secure()`.

### Startup sequence (`main.dart`)
1. `library.load()`, which runs the sweep above.
2. Ingest leftovers. Any files in `inbox/`, plus Android `ImagePicker().retrieveLostData()`, go into a new **"Recovered scan"** document. Ingest skips paths that no longer exist. A scan result that reaches a recreated Android activity (process death, "Don't keep activities") is moved into the inbox by Kotlin, which then sends `inboxReady`; Dart installs that handler before the startup pass and runs one recovery pass at a time, so nothing is ingested twice. (Not a check on `AppLifecycleState.resumed`: that could take an ID card's front side while the user is still flipping the card.)
3. Wipe temp: `<Temp>/folio/`, printing's share copies (Android `<cache>/share/`) and iOS `tmp/`. We never wipe the whole Android cache, because ML Kit may still be handing over a result. `capture` deletes each picked file as soon as it has been ingested.

## 6. Native channel (`folio/native`)

| Method | Android (Kotlin, `MainActivity`) | iOS (Swift) | Returns |
|---|---|---|---|
| `scan({pageLimit?})` | `GmsDocumentScanning` in FULL mode with JPEG results. The in-scanner gallery button stays on (its default). Uses `startIntentSenderForResult` and `onActivityResult`, because `FlutterActivity` is not a `ComponentActivity`. Our request codes are handled first, then **`super.onActivityResult` is always called** so `image_picker` keeps working. Results are renamed from ML Kit's cache into `inbox/` on a background executor. | `VNDocumentCameraViewController` presented from the scene's top VC. Pages are written into `inbox/` on a background queue in an `autoreleasepool` loop. | JPEG paths in `inbox/`; `[]` means cancelled |
| `detectCorners(path)` | Returns `null` | `VNDetectDocumentSegmentationRequest` with the file's `CGImagePropertyOrientation`. Returns `[tl.x, 1−tl.y, tr.x, 1−tr.y, br.x, 1−br.y, bl.x, 1−bl.y]` (Vision's origin is bottom-left). | 8 doubles or `null` |
| `saveAs(path, name)` | SAF `ACTION_CREATE_DOCUMENT` (`application/pdf`) followed by a stream copy in mode `"wt"` (an overwrite pick returns the existing file; plain `"w"` doesn't truncate it) | `UIDocumentPickerViewController(forExporting:asCopy:)` | `bool` saved |
| `openSettings()` | — | `UIApplication.openSettingsURLString` | — |

Rules:
- **Duplicate guard.** Dart keeps a `_scanning` flag and disables the buttons while it is set. Native never returns "busy". A new call resolves any stale pending result with `[]` and then proceeds.
- **VisionKit Done race.** If Done is tapped right after capture, VisionKit may never call its delegate. `VNDocumentCameraViewController` can't be subclassed (its `init` returns a private class), so a clear, full-screen host controller of ours presents it and owns the pending result: when the camera goes away without a delegate call the host appears again and resolves with `[]`, and the host's own `viewDidDisappear` does the same as a last resort (**device-verify**).
- **Unavailable.** Swift returns `unavailable` on the Simulator (`targetEnvironment(simulator)`), on `isiOSAppOnMac`, and when `!isSupported`. Kotlin maps any `getStartScanIntent` failure to `unavailable`, with no RAM or GMS pre-checks. `installModules` runs fire-and-forget at first launch. iOS returns `denied` when `AVCaptureDevice.authorizationStatus` is `.denied`.
- **Registration.** The iOS channel is registered in `didInitializeImplicitFlutterEngine` (UIScene). `AppDelegate` sets `isExcludedFromBackup` on the whole Application Support folder (it holds `library/` and `inbox/`) at every launch (D4).

## 7. Image pipeline

1. **Ingest** (`capture.dart`, one file at a time, cancellable between files).
   - Scanner pages are moved from `inbox/` to `src/` as-is (already cropped and upright, with filter Original).
   - Imports use `pickMultiImage(maxWidth: 4000, maxHeight: 4000, imageQuality: 95, requestFullMetadata: false)`. The plugin resizes every pick natively before it returns. Each file is checked by its magic bytes. JPEG is copied as-is. Anything else goes through `decodeImage` in the isolate, gets its alpha composited over white, and is written as JPEG q92. Files that can't be decoded (for example HEIC on Android 7–8) are skipped and listed in a banner.
   - Next, `detectCorners` runs (iOS), and the page starts with filter Enhance.
2. **Render** (`render.dart`, one serial queue of `Isolate.run` calls that pass paths, not bytes):
   - decode, pre-shrinking first when the quad's long edge is more than 2× the output long edge (to avoid aliasing);
   - homography warp with bilinear sampling, with rotation fused in by shifting the corner order;
   - output size = the larger of each pair of opposite edges, capped at the preset long edge (1100 px for ID-card documents) and never upscaled;
   - one composed 4×5 colour matrix;
   - for B&W only, a Bradley adaptive threshold on an integral image, window = width / 16;
   - `encodeJpg(quality: preset, chroma: yuv420)`, always 3-component RGB and EXIF-free;
   - write `cache/<pageId>-<r>.jpg` via tmp + rename, delete the previous render, and save the new `r`.
   - **Invariant: the PDF embeds only `render()` output, never `src` files.** This keeps GPS EXIF from imports out of every PDF.
3. **What the user sees.** Every page has **exactly one** derived file, rendered in the background at the document's quality after each edit. Thumbnails, Review Pages, Crop & Enhance and the preview all show it through `Image.file(cacheWidth:)`. While a render is pending, the previous image (or `src`) shows with a thin progress bar. Filter chips are small `ColorFiltered` previews of the page thumbnail; B&W uses a high-contrast grayscale matrix as an illustration. Crop mode shows `src` with the quad overlay and no live warp.
4. **Quality presets**, given as long edge / JPEG quality:
   - Small: 1600 px / 60 (about 135 dpi on A4)
   - Standard: 2200 px / 75 (about 190 dpi)
   - High: 3000 px / 85 (about 255 dpi)

   Exporting at the document's quality is pure pass-through of the cached renders. Changing the quality in the export sheet re-renders the pages and saves the new quality on the document.

## 8. Screen-by-screen UI/UX

**Design language:**
- **Overall:** quiet Material 3 with neutral surfaces and one ink-blue accent seed. Generous whitespace, 16 dp radii, and the pages themselves supply the colour.
- **Typography:** the platform default (SF / Roboto) with a large title, and tabular figures for counts and dates.
- **Motion:** a hero from thumbnail to editor, 200 ms fades, and a slight scale on press.
- **Theme:** light and dark follow the system.
- **Accessibility:** every icon button has a tooltip and a semantic label.

| # | Screen | Content and behaviour | States |
|---|---|---|---|
| 1 | **Home / Library** | Large title "Documents", a search field and a sort menu (Recent / Name). A two-column grid of **paper stacks**. Each tile shows the document's first page at its real proportions, so a receipt reads as a tall slip and a business card as a small card. Up to two sheets sit behind it to show the page count. Name, page count and date are below. The ⋯ menu has Rename · Duplicate · Share PDF · Delete (with a confirm dialog). The bottom action bar has a primary **Scan** with secondary **Import** and **ID card**. | Empty ("Scan your first document"); no search results; damaged row ("Can't open", Delete / Keep) |
| 2 | **Scanner** | The OS scanner, full screen. Not our UI. | Unavailable sheet (the reason, plus **Import photos** / **Take photo**); permission-denied sheet (**Open Settings**) |
| 3 | **Crop & Enhance** | A pager over the new pages (after an import) or over all pages (opened from Review Pages). The page sits centred on a dim backdrop. Tools: **Crop · Rotate · Filter · Retake · Delete**. The filter strip has 4 chips plus **Apply to all**. Then **Done**. | Rendering bar; "Page image missing" (Replace / Delete); import progress "Adding 3 of 8…" with Cancel |
| 4 | **Crop** | The source image with a 4-handle quad, a translucent mask outside it, and a magnifier loupe while dragging. Actions: **Auto** (detected) · **Full** · **Reset** · **Done**. A non-convex quad turns the handles red and disables Done. | — |
| 5 | **Review Pages** | An editable title. A `ReorderableListView` of page cards, each with a large thumbnail, "Page 2", the filter name, a drag handle, and a ⋯ menu (Duplicate · Replace · Delete). Tapping a card opens Crop & Enhance at that page. The bottom bar has **Add page** (Scan / Import) and a primary **Export PDF**. An ID-card document with 1 page shows the banner "Add the back side". | Per-card rendering; "2 photos couldn't be added" banner; delete-undo snackbar |
| 6 | **Export sheet** | A bottom sheet with a file name field, segmented **Fit · A4 · Letter** (**A4 · Letter** for ID cards, where Fit means A4), and segmented **Small · Standard · High**. **Preview** opens a pager of white pages drawn from `layout()`. Then **Save to device · Share · Print**. | Exporting (buttons disabled, Cancel); preview building; success snackbar "Saved · 1.2 MB"; error with Retry |
| 7 | **ID card guide** | A bottom sheet. Step 1 "Front side" leads to the scan; step 2 shows the front thumbnail and "Now flip the card", then the scan. It ends on Review Pages, with the export composing both sides onto one page. | Cancelled scan returns to the current step; scanner unavailable offers "Import front / back" |

There is no settings screen in v1. Quality and page size are remembered per document. The theme follows the system. "About & licences" sits in the Home overflow menu and opens `LicensePage`.

## 9. Milestones

**QA loop (run at the end of every milestone):**
1. Run `tool/check.sh`: `dart format --set-exit-if-changed .`, `flutter analyze`, `flutter test`, `flutter build apk --debug` and `flutter build ios --simulator --no-codesign`.
2. Check `flutter pub deps --no-dev` against the §4 allow-list. Any new manifest, plist or Gradle entry is recorded in §12.
3. Fix whatever our changes broke.
4. Write a summary covering files changed, features, test results and open issues.
5. Update this document.

Nothing is committed or pushed without your say-so. Items that can only be checked on a device are reported as **unverified** until they have been tested on hardware.

| M | Scope | Acceptance | Est. |
|---|---|---|---|
| **M0 Setup** | Pin 3.47.8 with FVM (D2). `flutter create --org <D6> --platforms ios,android`. Lints, theme, file skeleton, `tool/check.sh`. iOS 15, minSdk 24. | App launches on the iOS Simulator and an Android emulator; check.sh is green | 0.5 d |
| **M1 UI shell + screenshots** ✅ | Every screen in §8 with generated fixture documents, in light and dark, with the §13 states. Progress, busy and error states move to M3b/M5, where they become real. | **Screenshot set delivered for your design sign-off**; Home and Review Pages widget tests | 2 d |
| **M2 Library** ✅ | `document.dart` page ops, the real `Library`: JSON, atomic writes, load sweep, damaged documents, CRUD, duplicate, search and sort, startup sequence | Unit tests on a temp dir, covering crash leftovers, orphans, damaged JSON, page ops and the temp wipe; data survives a restart | 1.5 d |
| **M3a Render + spike** ✅ | `render.dart`, PNG/HEIC ingest, serial queue. **Low-end Android release-build spike:** go/no-go on adding native resize/encode (about 40 lines per platform). | Homography maps corners exactly; output dims for each rotation; threshold on synthetic text; no APP1/EXIF in output; 20 × 48 MP imports without OOM on Android + iPhone | 2 d |
| **M3b Editor** ✅ | Import flow, Crop & Enhance pager, filters, Apply to all, rotate, crop view, reorder, duplicate, replace, delete/undo, import cancel | Widget tests: import → Crop & Enhance → Review Pages; reorder updates the model and the export order; crop clamping and convexity; cancel keeps ingested pages | 2.5 d |
| **M4 Native scanners** ✅ | Kotlin: ML Kit, inbox, `super` result forwarding, module prefetch, unavailable. Swift: VisionKit, Done race, denied, unavailable, Vision corners, backup flag. Retake. | Channel contract tests with a mock handler; **device checklist §10.4** on 1 Android phone + 1 iPhone | 4 d |
| **M5 Export** ✅ | `layout()`, `buildPdf` in an isolate (pass-through, Fit/A4/Letter), preview, Save, Share (with iPad bounds), Print, cancel, filenames | Unit tests: page order; exact point sizes per mode; `/DCTDecode` + `/DeviceRGB` present; size ≈ Σ JPEGs + < 5 %; preview rects == PDF rects. Opens in Acrobat, Chrome, Preview, Drive and Gmail. | 2 d |
| **M6 ID card** ✅ | Guide sheet, idCard layout in `layout()`, 1100 px side cap | Layout tests: horizontal ID-1 at 85.6 mm; vertical + vertical on Letter; mixed orientation; non-ID-1 cards; shrink-to-fit | 0.5 d |
| **M7 Hardening** ✅ | Backup exclusion (D4), `PrivacyInfo.xcprivacy`, accessibility pass (TalkBack/VoiceOver, 200 % text), edge-to-edge, 100-page document, 16 KB alignment check, release builds, TestFlight print check, licence notices (`image` + ML Kit `third_party_licenses`) | Every release criterion in PRD §8 | 2 d |
| **M8 OCR (optional)** ✅ | Native OCR channel (ML Kit unbundled / Vision), Copy text, searchable PDF that falls back to no text layer when `save()` fails | Text is findable in Acrobat/Preview search; OCR never blocks an export | 3 d |

Total through M7 is about **17 dev-days**. The M1 screenshots arrive about 2.5 days after approval.

## 10. Testing strategy and acceptance

1. **Unit tests** (`test/`) cover:
   - render maths: homography, rotation dimensions, matrices, threshold, and EXIF-free output;
   - ingest: PNG with alpha becomes JPEG on white, and undecodable files are skipped;
   - `Document` JSON round-trips, including unknown fields and `v`;
   - page operations;
   - `Library` against `Directory.systemTemp`: CRUD, atomicity, orphan and `.tmp` sweep, damaged documents, case-insensitive search, and sort;
   - the startup sequence: inbox leftovers are ingested before the temp wipe;
   - `layout()` and `buildPdf`;
   - filename sanitising.
2. **Widget tests** cover:
   - Home: empty, list, search, sort, rename, and delete-confirm;
   - Review Pages: reorder;
   - Crop & Enhance: filter and Apply to all;
   - crop clamping;
   - the export sheet: disabled while busy, and cancel;
   - import cancel;
   - channel errors (`unavailable`, `denied`, cancel) via `TestDefaultBinaryMessenger.setMockMethodCallHandler`.
3. **Integration tests** (`integration_test/`) cover the import → edit → export flow, using a fake `ImagePickerPlatform` on the Simulator and the emulator. They also do a screenshot run:
   - the fixture library is generated at test start (synthetic JPEGs written with `image`, plus `doc.json`) into a temp root, so the app ships no demo code;
   - Android calls `convertFlutterSurfaceToImage()` before `takeScreenshot`;
   - native sheets are captured with `xcrun simctl io booted screenshot` / `adb exec-out screencap`.
4. **Device checklist** (manual, every release):
   - **Android:**
     - module download on first run;
     - auto-capture;
     - flash toggle present;
     - the in-scanner gallery button auto-crops;
     - kill the app during a scan, during the camera fallback and during an import, then confirm the pages are recovered;
     - an emulator image without Play services, to exercise the fallback;
     - Honor/Huawei, if available;
     - `adb shell bmgr` shows no `library/`.
   - **iOS:**
     - auto-capture;
     - Done tapped immediately;
     - camera denied, then Open Settings;
     - an import with a rotated photo (EXIF 6) gets the right corners;
     - iCloud Manage Storage shows no library data.
   - **Both, with every content type:** A4 letter, long receipt, single book page, business card, 6×4 photo, ID front + back.
   - **Export:** Save-As over an existing name; Print from a TestFlight build; share to Gmail and Drive.
   - **Scale and accessibility:**
     - 20 × 48 MP import on 4 GB devices;
     - a 100-page export;
     - TalkBack and VoiceOver, including reordering pages.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pure-Dart JPEG **decode** is slow on low-end Android. M3a measured realistic 12 MP imports at 0.49 s/page on the Mac (AOT); low-end phones are typically 5–8× slower, so an estimated 2.4–3.9 s/page. Decode is about 60% of the time; warp + filter ~20%; encode ~10%. | Renders run in the background, edited pages jump the queue, and export passes cached renders through. M3b: import at `imageQuality` 85–90, not 95 (~20–30% faster decode). **Trigger for native decode:** on a real low-end Android (A53/A55, 2–3 GB) in a release build, median 12 MP Standard render > 1.5 s, or decode > 1 s. Then add a native downscaled decode (Android `ImageDecoder.setTargetSize`, iOS `CGImageSourceCreateThumbnailAtIndex`) returning RGBA to the render isolate; the warp, filters and encode stay in Dart. |
| iOS `pickMultiImage` decodes every pick at full size (about 192 MB for 48 MP) | Test on a 4 GB iPhone in M3a. Fallback: a Swift PHPicker that writes each pick through ImageIO `CGImageSourceCreateThumbnailAtIndex` (about 40 lines; it also strips GPS). |
| ML Kit is unavailable (no Play services, under 1.7 GB RAM, the Huawei dual GMS/HMS crash loop) or the first-run module download stalls | Every failure maps to `unavailable`, which falls back to Take photo or Import with manual corners. Prefetch the module at first launch. Test on devices. |
| ML Kit's flash toggle and in-scanner gallery auto-crop are undocumented | Verify on a device in M4. If missing, accept it as an OS-scanner limitation under D1. |
| OS scanners return only cropped output | Treat that output as the original (§3). Imports stay fully non-destructive. |
| A scan is lost to the VisionKit Done race or Android process death | iOS: our host controller resolves a scan the camera never reported. On Android, use the `inbox/` handoff, `inboxReady` and `retrieveLostData()`, ingesting into "Recovered scan". |
| Book pages: no curve flattening or spread splitting | The guide copy says "Scan one page at a time". Dewarping is out of scope for v1. |
| Memory with long documents | Ingest is serial and rendering uses a serial isolate. Pass paths, not bytes. Test a 100-page export. `PdfImage.jpegStream` is safe if needed, because every render is RGB. |
| Printing from SwiftPM App Store builds (`dart_pdf` #1961/#1974 still open) | A print from a TestFlight build is a release gate. Fallback: the share sheet's Print action. |
| Privacy: OS cloud backups copy ID scans, and ML Kit sends usage telemetry | D4: Android `allowBackup="false"` plus a `<device-transfer>` exclusion in `dataExtractionRules`, and the iOS `isExcludedFromBackup` flag. Privacy copy says "documents never leave your device"; the Play Data safety form discloses ML Kit diagnostics. |
| Store compliance: Android 16 edge-to-edge, 16 KB page size, iOS privacy manifest, UIScene | SafeArea everywhere and `PopScope`. An alignment check (`zipalign -c -P 16`) and `PrivacyInfo.xcprivacy` in M7. Register the channel the UIScene way. |
| SDK churn: Flutter 3.47 and the `material_ui` migration | Pin with FVM and commit `pubspec.lock`. Run `dart fix` when SDK Material is deprecated. |
| The scanner UI can't match our design | Accepted trade-off (D1). Our screens own everything before and after capture. |

## 12. Platform configuration (only what's required)

- **Android:**
  - the ML Kit Gradle dependency;
  - **no** CAMERA permission;
  - `android:allowBackup="false"`;
  - `android:dataExtractionRules` → `<exclude domain="file" path="."/>` in both `<cloud-backup>` and `<device-transfer>` (Android 12+; the whole files dir: `library/`, `inbox/` and the scanner's `.part` staging file);
  - minSdk 24.
- **iOS:**
  - `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`;
  - deployment target 15.0;
  - `PrivacyInfo.xcprivacy`: no tracking, no collected data, File Timestamp C617.1 (Dart's `File.stat` on files in the app's own folders; Flutter.framework and `image_picker_ios` ship their own manifests);
  - the channel and backup flag in `AppDelegate` (UIScene).
- Every later addition is recorded here, with the reason it is needed.

## 13. Screenshots (your review request)

Once this plan is approved, **M0 + M1** deliver a clickable UI shell with realistic generated documents. They also deliver a screenshot set on an iPhone 17 Pro Simulator and a Pixel emulator, in light and dark. It covers:
- Home: empty, populated and damaged-row states;
- Crop & Enhance with the filter strip;
- Crop with the loupe;
- Review Pages, including the failed-import banner;
- the Export sheet and Preview;
- the ID card guide;
- the scanner-unavailable and permission-denied sheets.

Engine work (M2 onward) starts only after you sign off the look. The OS scanner screens can't appear in Simulator screenshots, because VisionKit needs a real camera.

## 14. Progress log

### M0 Setup ✅ (2026-10-27)
- **SDK:** FVM 4.3.2 installed with Homebrew; the project pins Flutter **3.47.8** / Dart 3.13.7 in `.fvmrc`. The global 3.41.8 (used by ThisKrit) is untouched. Run every command through `fvm flutter …`.
- **Project:** created with `flutter create --org com.folio --project-name folio --platforms ios,android --empty`.
  - Bundle ID / applicationId: `com.folio.scan`. The Android namespace stays `com.folio.folio`.
  - Display name: "Folio".
  - iOS deployment target 15.0; Android minSdk 24 (template defaults).
- **Formatter:** `analysis_options.yaml` sets `formatter: page_width: 140`.
- **QA script:** `tool/check.sh` runs format, analyze and test; add `--builds` for debug APK and iOS simulator builds.
- **Environment note:** on this Mac, Gradle's JVM could not download from GitHub's CDN (it timed out, while curl worked). Gradle 9.3.1 was fetched once with curl into `~/.gradle/wrapper/dists`, and Android builds run with `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true`. No project files were changed for this.

### M1 UI shell + screenshots ✅ (2026-10-27)
- **Screens built:**
  - Home (empty, grid, search, sort, damaged tile);
  - the scanner-unavailable and camera-denied sheets;
  - the ID card guide (front, then back);
  - Review Pages (reorder, duplicate, delete with undo, notice banner);
  - Crop & Enhance (filter strip, Apply to all, rotate, delete with undo);
  - Crop (4 handles, loupe with crosshair, convexity check, Auto / Full / Reset);
  - the Export sheet and Preview.
- **Implemented early, because the UI needs them:**
  - `layout()` in `pdf.dart`: the page geometry for Fit / A4 / Letter and the ID-card rule, with unit tests;
  - `squareToQuad` and `isConvex` in `render.dart`;
  - the pure page operations on `Document`.
- **Placeholders:** these actions show "Available in the next build" (`notYet()`):
  - Import, Take photo and Replace (M3b);
  - scan ingest and ID-card document creation (M4);
  - Save, Share and Print (M5).
- **No native code yet.** Scan reaches the real "unavailable" path through `MissingPluginException`.
- **Deviations from the plan:**
  - The Home list became the paper-stack grid (§8).
  - Shared widgets live in `ui.dart`.
  - `DocPage.w/h` is the size of the image as shown (the render if there is one, otherwise `src`), and `size` applies rotation only to an unrendered `src`.
  - The duplicate-scan guard is a single `scanning` notifier in `capture.dart`.
- **Review:** three independent reviewers (design, correctness, simplicity) looked at M1. Fixed as a result:
  - the rename dialog used its controller after dispose;
  - Undo restored a stale snapshot of the whole document;
  - half of each crop handle could not be touched;
  - snackbars were hidden under sheets;
  - the tile menu had a 32 dp target;
  - the editor overflowed at 200 % text;
  - the Export sheet sat inside the home-indicator zone;
  - loose letter-spacing, heavy toolbar titles, misaligned grid tiles, an off-palette segmented button, and a loupe that hid the corner.
- **Second review:** a further independent pass checked that the fixes held. Fixed as a result:
  - the dock and editor tool row overflowing at 320 dp and 250 % text;
  - the snackbar hidden under the ID-card sheet;
  - Undo letting an ID card reach 3 sides;
  - sheets sliding under the status bar at very large text;
  - the Undo snackbar timing out for screen-reader users;
  - the loupe being dimmed by its own shadow;
  - a crosshair that was hard to see;
  - home-tile meta text truncating on 360 dp phones;
  - back sheets clipped in the paper stack;
  - segmented-control outlines below 3:1 contrast;
  - filter thumbnails not following rotation.
- **Tests:** 15 unit and widget tests pass; `flutter analyze` reports 0 issues.
- **Screenshot runs:** the `integration_test/screenshots_test.dart` run passes on the iPhone 17 Pro Simulator (iOS 26.5) and on an Android 15 emulator. The same run builds both debug apps.
- **Screenshots:** 14 screens × light/dark × iOS/Android = 56 PNGs in `screenshots/` (git-ignored). Regenerate them with:
  `fvm flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screenshots_test.dart -d <device>`
- **Not verified:**
  - The OS scanner UIs can't appear on the Simulator or emulator; they need hardware (M4).
  - Fixture pages are generated PNGs. Real JPEG renders come in M3a.

### M2 Library ✅ (2026-10-28)
- **`lib/library.dart`** is now disk-backed:
  - one folder per document plus `doc.json` v1;
  - an atomic manifest write (tmp, `flush`, then `rename`);
  - one serial write queue: memory updates at once, and the write is queued;
  - the load sweep (see §5);
  - damaged documents (unreadable, or a newer `v`);
  - delete by rename then delete;
  - duplicate by copying into `<id>.tmp`, then rename;
  - `newDocument`, `addImage` (copy plus a header-only size read) and `imageSize`.
- **`lib/document.dart`:**
  - `toJson` / `fromJson`, which rejects any path that isn't `src/<word>.jpg` or a `\w+` render id;
  - `renderPath` = `cache/<r>.jpg`;
  - `copyWith(dir:)`.
- **`lib/capture.dart`:**
  - `ingest`: copy in, save, then delete the inputs; append to the latest version of the target; return null if the target was deleted meanwhile; throw if the save fails, keeping the inputs;
  - `recoverInbox`: turns inbox leftovers into a "Recovered scan" document.
- **`lib/main.dart`:**
  - startup runs `Library.open`, then `recoverInbox` (which can never block launch), then `wipeTemp(<temp>/folio)`;
  - a write failure shows a snackbar through `messengerKey`.
- **Dependency added:** `path_provider` 2.1.6. That is the only new package.
- **Review:** one independent review found the following; each now has a regression test.
  - Inputs were moved before the manifest was durable, so a crash could lose a page or leave it behind as an "Unreadable document".
  - `save()` never failed for callers that awaited it.
  - The `v` field was ignored.
  - The path guard missed the render id.
  - Ingest could revive a document deleted while it ran.
  - `duplicate` copied fields by hand, which would silently drop new ones.
- **Tests:** 31 unit and widget tests, 16 of them in `test/library_test.dart` on a real temp directory:
  - restart persistence of every edit;
  - round-trip with unknown fields;
  - path guard;
  - newer-version manifests;
  - sweep of crash leftovers and orphans;
  - damaged documents;
  - an independent duplicate and a folder delete;
  - 20 rapid saves landing in order;
  - failed-write reporting;
  - a crash before the first save;
  - a failed save keeping its inputs;
  - a target deleted during ingest;
  - inbox recovery;
  - the temp wipe.
- **On-device tests:** `integration_test/persistence_test.dart` passes on the iPhone 17 Pro Simulator and the Android 15 emulator. It covers:
  - real app directories;
  - a rename and a page delete made through the UI, then a reload from disk;
  - a cold start through the real `main()`.
- **Regression:** the screenshot run (56 shots) still passes on both platforms.
- **Second check:** a further verification pass could not break the fixes. Its one remaining point is now fixed: copied page files are fsynced before the manifest that references them is written, so a power loss can't leave an empty page.
- **Not done here, by plan:**
  - OS backup exclusion (Android `allowBackup` / iOS `isExcludedFromBackup`) is M7;
  - `image_picker` `retrieveLostData` comes with import in M3b;
  - the inbox check on app resume comes with the native scanner in M4.

### M3a Render pipeline + performance spike ✅ (2026-10-28)
- **`lib/render.dart`** is pure Dart with no Flutter imports, so it runs in an isolate and in a command-line benchmark. It contains:
  - `renderSync`: JPEG decode with 2/4/8× shrink-while-decoding (the source is kept ≤ 2× the output so text doesn't alias); homography warp with clockwise rotation fused in; bilinear sampling; the same 4×5 colour matrices as the GPU preview; Bradley adaptive threshold for B&W; and an EXIF-free 4:2:0 JPEG written through tmp → fsync → rename;
  - `normalizeSync`: JPEGs are copied byte for byte; other formats are flattened onto white and re-encoded at q92, frame 0 only, capped at 24 MP;
  - `uprightSize`: reads the JPEG header plus EXIF orientation 1–8 without decoding pixels;
  - `stableHash`.
  - `PageFilter` moved here so the file stays Flutter-free; `document.dart` re-exports it.
- **Model:**
  - `Document.renderPreset` gives the long edge and JPEG quality from the quality setting (1100 px for ID cards);
  - `renderKey(page)` hashes src, corners, turns, filter and the preset with a version tag;
  - `isRendered`;
  - a render is stored at `cache/<key>.jpg`, shared by identical pages.
- **Library:**
  - every save or load queues pages whose render is stale or whose file is missing;
  - pages render one at a time in `Isolate.run`, with edited pages first;
  - a finished render updates `r` and `w`/`h` without bumping the modified date, then deletes the replaced render if nothing still uses it;
  - failures are retried on the next save and show an error badge;
  - `isRendering`, `renderFailed`, `renderIdle`.
- **UI:** `PageImage` keeps the previous image with a thin progress bar while a page renders. Crop reads the source size through `uprightSize` in an isolate.
- **Ingest** (`addImage`) now goes through `normalizeSync`, which reads the upright size the same way the renderer does.
- **Dependency added:** `image` 4.12.0 (MIT). Its `LICENSE-other.md` notice is registered in M7, as planned.
- **Performance (realistic synthetic photos, q95 with sensor noise):**

  | Case | Mac AOT, per page |
  |---|---|
  | Scanner page (A4, 8.7 MP) | 0.36 s |
  | 12 MP import, perspective crop | 0.49 s |
  | 12 MP import, B&W | 0.48 s |
  | 12 MP import, High | 0.62 s |
  | 48 MP photo | 1.34 s |
  | ID-card side | 0.34 s |

  - The Android arm64 emulator in a profile (AOT) build gives similar figures, because it runs on the Mac's cores. These are **upper-bound speeds, not low-end evidence**.
- **Memory:** 20 photos of 48 MP imported and rendered through the real library, five of them with tight crops that force full-size decodes. RSS was 165 MB before rendering and peaked at 317 MB, on a 2 GB Android emulator. No out-of-memory crash on Android or on the iOS Simulator.
- **Go/no-go:** stay **pure Dart for now** (provisional). It meets the target on mid-range phones by estimate. Low-end phones are estimated at 2.4–3.9 s per page, which is over the 1.5 s target, so the decision waits on a **real low-end Android** run of `integration_test/render_bench_test.dart`. The trigger and the native path are in §11.
- **Review:** an independent review found the following, each fixed with a regression test:
  - an Undo could restore a page whose shared render had just been deleted, so it showed no image;
  - render failures were silent and never retried;
  - a mirrored crop passed the shape check;
  - huge PNGs could exhaust memory (a 1 MB file can declare 268 MP);
  - the benchmark input was unrealistically easy;
  - edited pages waited behind the import backlog;
  - two cheap inner-loop optimisations.
- **Second check:** a further verification pass found two side effects of those fixes, both now fixed:
  - a retry cleared failed renders in every document (so other documents spun forever), and is now scoped to the edited document, with a test;
  - an image re-created at a path that had failed to load stayed "Page image missing"; images now reload whenever a render lands, confirmed with the reviewer's own probe.
- **Tests:** 46 unit and widget tests (`test/render_test.dart` covers the warp corners, rotations, the size cap, shrink-decode, no EXIF, EXIF orientation, B&W under uneven light, PNG transparency, the pixel cap, render keys, the re-render flow, queue priority, Undo after shared-render deletion, and failure handling). The persistence device tests pass on iOS and Android. The screenshot run (56 shots) now renders every fixture page through the real pipeline, including a real perspective crop of the photographed lease page.
- **Not verified:**
  - timings on a real low-end phone (`fvm flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/render_bench_test.dart -d <phone>`);
  - memory on a real 4 GB iPhone. The iOS import path through `image_picker` is M3b.

### M3b Import + editor flows ✅ (2026-10-28)
- **Capture** (`lib/capture.dart`). One entry point, `capturePages(source)`, used by every button. It:
  - runs the OS scanner, or, when the scanner can't run, takes the user's **Import photos / Take photo** choice from the explanation sheet;
  - trims scanner results to the page limit (VisionKit can't enforce one) and deletes the extras;
  - shares one duplicate-capture guard across all entry points.
- **Photo picker.** `image_picker` (with its Android and platform-interface packages, to turn on the Android Photo Picker) brings photos in at 4000 px and quality 90, the M3a speed win. Same-name Android copies are de-duplicated and reported. Picker errors show as dialogs, so they're visible above sheets.
- **Flow.** Scan or Import → ingest with a progress dialog and **Cancel** (pages already added are kept) → imported pages start on **Enhance**, with detected corners preset inside the import loop (iOS Vision arrives in M4; the result is null until then) → **Crop & Enhance** → **Done** → **Review Pages**. Scanner pages skip Crop & Enhance (Original filter). Files that couldn't be added show a banner on a new document, or a toast when adding to an existing one.
- **Editing actions:**
  - Add page (Scan / Import) appends to the document; ID cards are capped at 2 sides;
  - **Replace** (Review Pages menu) and **Retake** (Crop & Enhance; uses the scanner, or the fallback when it can't run) keep the page's place, with Undo;
  - the **ID card** guide passes both sides back, and a real `idCard` document is created through the same path.
- **Storage and recovery:**
  - a full disk is reported as storage, not as a bad file;
  - Android lost-pick recovery runs at launch and before every pick;
  - the picker's temporary copies are deleted after ingest; copies left from earlier sessions are removed at launch on iOS (tmp `image_picker_*`) and, on Android, just before the session's first pick, after lost-pick recovery (cache UUID and `scaled_*` entries older than the launch).
- **Platform config.** iOS `NSPhotoLibraryUsageDescription` and `NSCameraUsageDescription`. Android needs no permissions.
- **Review found and fixed:**
  - the Android picker leaked full-size copies into its cache and collapsed same-name photos;
  - lost-pick recovery ran too early and could be erased;
  - the scanner page limit wasn't enforced;
  - corner detection ran as a second save pass and wasted renders;
  - a full disk was mislabelled as a bad file;
  - toasts were hidden under the ID sheet;
  - the cancel count was wrong;
  - an Undo used a disposed context;
  - camera error codes were mapped wrongly;
  - the progress helper was folded into its single caller.
- **Second check** (fix verification) found and fixed two more:
  - the Android launch sweep could delete a camera photo that lost-pick recovery hadn't collected yet; the sweep now runs after recovery, before the first pick;
  - an ID-card back photo with the same Android file name could overwrite the front; the front is renamed (`.front`) as soon as it's captured.
- **Notes for M4:**
  - Use a Kotlin-triggered `inboxReady` call for scans that finish after process death, instead of a Dart check on app resume. Otherwise a resume check could take the ID-card front side while the user is still flipping the card.
  - Implement iOS `openSettings` and Vision `detectCorners`.
- **Tests:**
  - 50 unit and widget tests, including: reorder updating both the model and the export order; corners preset during ingest; the full-disk check; the picker leftover sweep.
  - `integration_test/editor_test.dart`: 8 tests run on the iOS Simulator and the Android emulator with a fake picker:
    - import → Crop & Enhance → Review Pages, with bad files reported and picker copies cleaned up;
    - Cancel keeping the pages already added, with the exact count;
    - crop clamping, the mirrored-shape block, and saved corners;
    - Replace with Undo;
    - duplicate names;
    - Retake keeping only the first scanned page;
    - Take photo when there's no scanner;
    - the full ID card flow.
- **Not verified:**
  - the real system pickers and camera, and Android process death during a pick (device checklist §10.4);
  - picker memory on a real 4 GB iPhone.

### M4 Native scanners ✅ (2026-10-28)
- **Android** (`MainActivity.kt`, 127 lines with comments):
  - ML Kit Document Scanner 16.0.0 (FULL mode, JPEG, `setPageLimit` for Retake and ID sides) through `startIntentSenderForResult`, because `FlutterActivity` is not a `ComponentActivity`. `super.onActivityResult` always runs first, so `image_picker` keeps its results.
  - Results move from ML Kit's cache into `<filesDir>/inbox` (= `getApplicationSupportDirectory()/inbox`) as `scan-<ms>-<NNN>.jpg` on one background thread per process. A failed rename is copied to a `.part` file outside the inbox first, so the inbox only ever holds whole pages.
  - With no Dart call waiting (activity recreated), Kotlin sends `inboxReady` once the pages are in the inbox.
  - Any failure to start the scanner is `unavailable`. The module is prefetched at launch, only when Play services is usable, with the application context (an Activity context made Play services show its error dialog at every cold start).
- **iOS** (`AppDelegate.swift`, 172 lines including the template):
  - A clear, full-screen host controller presents the stock `VNDocumentCameraViewController` and owns the pending result. The plan's subclass idea was wrong: VisionKit's `init` returns a private class, so a subclass's properties and overrides never run. The host resolves a scan the camera never reported (the Done race) when it appears again, and in `viewDidDisappear` / `deinit` as last resorts.
  - `unavailable` on the Simulator, on Mac and when unsupported; `denied` when camera access is denied or restricted. Only the first `pageLimit` pages are written, as JPEG 0.9, each in its own autorelease pool.
  - `detectCorners`: Vision document segmentation with the file's EXIF orientation, y flipped to a top-left origin, ignoring answers below confidence 0.5 (with no document Vision still returns a whole-frame box at confidence 0). The same request on this Mac finds a synthetic rotated sheet to within 0.003 at confidence 0.99, which confirms the mapping. `openSettings`. The whole Application Support folder is excluded from backups (D4).
- **Dart.**
  - `Native.onInboxReady` is installed before the startup inbox pass, and recovery passes run one at a time, so a late Android result is ingested exactly once.
  - `ingest` frees its own copies when the disk is full, so a failed recovery can't keep the disk full.
  - The Dart page-limit trim was removed, because both native sides enforce the limit. Crop's **Auto** button is hidden on Android, where there is no detector.
- **Review found and fixed:**
  - the VisionKit subclass (memory corruption on a real iPhone);
  - the Play services dialog or notification at every launch on phones without it;
  - a non-atomic copy into the inbox;
  - a thread leaked per activity recreation;
  - orphaned copies after a full-disk ingest;
  - dead trim code;
  - Vision's "nothing found" answer being preset as whole-frame corners (found on the Simulator).
- **Tests:**
  - 57 unit and widget tests, including channel contract tests (result and error mapping, `inboxReady` from the platform, overlapping recovery passes, a failed pass not blocking the next, full-disk cleanup).
  - `editor_test.dart` mocks `unavailable` wherever it taps Scan (the emulator has Play services). It adds an iPhone-only test where real Vision finds a rotated sheet's corners on import. It is skipped on the Simulator, whose Vision can't find documents: its first answer is the confidence-0 whole-frame box, and later ones are the same wrong box at confidence 0.83–0.99, from a CPU fallback.
- **Emulator check with the real scanner.** Tapping Scan launched ML Kit's activity through our intent sender. The emulator image can't download the scanner module ("Something went wrong"; it has no signed-in Play account), and Cancel returned to Home with nothing added and an empty inbox. A module download failure therefore looks like a cancel; the user can still use Import.
- **QA setup.** iOS device tests now run on a dedicated "Folio QA" simulator (iPhone 17, iOS 26.5). Another project's UI tests were driving the shared iPhone 17 simulator, which pushed our app to the background and hung our runs.
- **Not verified (device checklist §10.4):**
  - a real ML Kit scan, `inboxReady` after process death, flash and in-scanner gallery;
  - VisionKit on an iPhone: the Done race, denied then Open Settings, and the host presentation over a focused text field;
  - Vision corners on EXIF-rotated photos from a real camera;
  - the backup exclusion in iCloud settings.

### M5 Export ✅ (2026-10-28)
- **PDF** (`lib/pdf.dart`):
  - `buildPdf` computes `layout()` on the calling isolate (the same geometry the preview draws), then builds in `Isolate.run` from paths with the low-level `pdf` API.
  - Each page embeds its cached render as the JPEG it already is (`/DCTDecode`, never re-encoded); duplicated pages share one image object. Content streams are uncompressed, a few bytes each.
  - The title is written as UTF-16BE when the name isn't plain ASCII. Output goes through a chunked stream, because `pdf`'s own stream copies everything written so far for each image, which made it 9× slower.
  - `fileNameFor` replaces characters file systems reject, trims spaces and dots, and caps the name at 100 characters and 240 UTF-8 bytes (Android's limit is 255 bytes).
- **Export sheet** (`lib/export_sheet.dart`):
  - **Share** uses `Printing.sharePdf`, anchored to the button for the iPad popover. **Print** uses `Printing.layoutPdf` and is done once the dialog has the PDF: Android otherwise waits until the job leaves the print queue, for up to 10 minutes.
  - **Save to device** writes `<temp>/folio/<name>.pdf`, calls `saveAs`, always deletes the temp file, and shows "Saved · 40 KB".
  - While exporting, every control is disabled and the sheet shows "Preparing PDF…" with Cancel. Closing the sheet also cancels, and nothing is written (X9). Errors show inline, and the buttons are the retry.
  - Home's tile menu has **Export PDF**.
- **`Library.rendered(id)`.** Export waits only for its own document. Its pages jump the render queue, failed renders are retried, and missing render files are re-created. An already-rendered document exports at once while another one's import is still rendering.
- **Native `saveAs`:**
  - **Android:** `ACTION_CREATE_DOCUMENT` and a copy on the io thread in mode `"wt"`. A failure deletes the document only if the picker had just created it (size 0): an overwrite pick or a recreated activity never deletes the user's own file.
  - **iOS:** `UIDocumentPickerViewController(forExporting:asCopy:)`, with a retained delegate that replies once.
- **Startup wipe** also clears printing's share copies: Android `<cache>/share`, and the `*.pdf` files in iOS `tmp/`.
- **Review found and fixed:**
  - Save over an existing file on Android left the old file's tail behind;
  - a failed or orphaned save could delete the user's existing file;
  - export waited for every document's renders;
  - Print stayed busy for the whole Android print job;
  - closing the sheet at the wrong moment could still share and pop the screen below;
  - long non-Latin names exceeded Android's 255-byte limit;
  - non-ASCII titles were garbled;
  - quadratic PDF writing;
  - "Try again" couldn't fix a failed render;
  - an exported page that was mid-render waited one extra render of another document.
- **Tests:**
  - 91 unit and widget tests, including `test/pdf_test.dart`:
    - page order;
    - exact `/MediaBox` per Fit, A4, Letter and landscape;
    - `/DCTDecode` + `/DeviceRGB` with byte-identical JPEGs;
    - size within 5 % of the JPEGs;
    - preview rects equal PDF rects;
    - names and titles.
  - Export-sheet widget tests cover busy, cancel, save, picker cancel, errors, Share and Print fakes, and closing mid-export; render-queue tests cover priority and the in-flight page.
  - `integration_test/export_test.dart` (Save and Share) passes on the iOS Simulator and the Android emulator.
- **Real system UI.**
  - Android emulator: the Photo Picker import, the "Save as" dialog, a valid 1-page PDF in Downloads at 595.28 × 793.7 pt, the share chooser and the print dialog with preview.
  - iOS Simulator: the photo picker, the Files export picker ("Replace Existing Items?" → Keep Both made `… 2.pdf`), "Saved · 40 KB", and the share sheet.
- **Known ceiling.** Every JPEG is held until the PDF is written, so the peak is about 3× the PDF (370 MB for 100 High pages). `PdfImage.jpegStream` would bring that to about 2× if M7's 100-page test needs it; a comment in `pdf.dart` records this limit.
- **Not verified (§10.4):**
  - opening the PDF in Acrobat, Chrome, Drive and Gmail;
  - printing from a TestFlight build;
  - the iPad popover position;
  - Save-As over an existing name on a real Android phone;
  - a 100-page export on a 4 GB phone.

### M6 ID card ✅ (2026-10-28)
Most of M6 already existed from M1–M3b:
- the guide sheet;
- `layout()`'s ID-card page;
- the 1100 px side cap;
- Front/Back labels, the "Add the back side" banner and the 2-side cap in Review Pages.

M6 closed the gaps against PRD §5.5:
- **Page size.** ID cards can print on Letter: the export sheet shows **A4 · Letter** for them (a stored Fit shows and prints as A4). Before, the control was hidden, so ID cards were always A4.
- **Scanner unavailable.** The "Scanner not available here" sheet now appears once: the back side is taken the same way as the front, and the button reads **Scan back**, **Import back** or **Take photo of back**. To support this, `Captured` records its real `Source` instead of a `scanned` flag; an extension keeps `.scanned` for existing call sites. Step 1 says "Added" rather than "Scanned" when the front came from photos.
- **Layout tests pin PRD I2:**
  - mixed orientation, with the back at half resolution so a vertical side wrongly taken for non-ID-1 would shrink;
  - the ±6 % ID-1 boundary;
  - a one-sided card;
  - Fit printing as A4;
  - Letter really giving a 612 × 792 pt page;
  - the 1100 px cap at every quality;
  - the worst case for shrink-to-fit. With two sides each at most 85.6 mm long, the stack is at most 183.2 mm and always fits A4 and Letter, so the shrink branch is a guard that can't trigger. It's kept, with a comment.
- **Other tests.** Widget tests cover the ID export sheet and the once-only problem sheet, for both gallery and camera. `editor_test`'s ID flow now uses **Import back**. The widget tests reset the global capture guard in `setUp`; one test had been leaving it set for the rest.
- **New screenshot:** `15_id_card_export`, in both themes.
- **Review** (2 lenses, findings verified) found only test gaps and the "Scanned" label; all fixed. Each new test was checked by mutation: the layout bug it targets makes it fail.
- **Not verified:** VisionKit and ML Kit ID scans on real phones, and a real print at 100 % checked with a ruler (§10.4).

### M7 Hardening ✅ (2026-10-28)
- **Backups (D4):**
  - **Android:** `allowBackup="false"` plus `dataExtractionRules` that exclude the whole files dir from cloud backup and device transfer. Verified on the emulator: the package flags have no `ALLOW_BACKUP`.
  - **iOS:** Application Support carries `com_apple_backup_excludeItem`, checked on the Simulator.
- **Privacy manifest.** `ios/Runner/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and File Timestamp C617.1. It's in the Runner target's resources and inside the built `Runner.app`.
- **Licence notices:**
  - `image`'s `LICENSE-other.md`, plus ML Kit's 63 third-party notices taken from its AAR.
  - The ML Kit notices are gzipped to 75 KB and are Android-only assets (`platforms: [android]`), so iOS doesn't carry them.
  - They're registered lazily in `lib/licenses.dart` and visible on the release build's licence page.
- **Accessibility:**
  - every control has a label;
  - page rows are one button with Move up / down / to start / to end actions, so reordering works without dragging;
  - crop corners have Move left / right / up / down actions and announce their position;
  - the Preview pager and filters are named, and sheet titles are headings;
  - the export busy and error text and the crop error are live regions;
  - the rename field is labelled.
- **Large text.** At 200 % text, labels shrink or wrap instead of being cut off.
- **Landscape.** Crop & Enhance puts its tools in a full-height side panel; before, the page shrank to 31 dp. Home, Review Pages, Crop & Enhance, Crop and Preview keep clear of landscape cutouts.
- **Tests.** Flutter's tap-target, label and contrast guidelines plus a 200 % text pass run over 8 screens in light and dark.
- **Edge-to-edge.** Transparent system bars with icon brightness that follows the theme, applied at the app root. Android keeps its scrim behind 3-button navigation. Checked on the emulator in a release build, in light and dark.
- **100-page document** (`integration_test/stress_test.dart`, from one 2400 × 1800 photo source). The 33 MB PDF (342 KB/page) builds in 120 ms on the Simulator and 225 ms on the emulator. Peak process memory is 414 MB on the Simulator and 474 MB on the emulator, about 70–100 MB over idle. Rendering 100 Standard pages takes 31–42 s in a debug build. The 20 × 48 MP case stays with `render_bench_test.dart`.
- **Release builds:**
  - APK (split per ABI), AAB (55.5 MB) and iOS (`--no-codesign`) all build.
  - **Size:** the arm64 APK is 20.0 MB, against 15.5 MB for a blank Flutter 3.47.8 app, so +4.5 MB, inside PRD §6's 5 MB.
  - **16 KB pages:** `zipalign -c -P 16` passes, and the ELF LOAD alignment of `libapp`, `libflutter` and `libdartjni` is ≥ 0x4000.
  - **R8 smoke test:** the release APK on the emulator imported from the real Photo Picker and saved a PDF through "Save as" with no crash.
- **Review** (3 lenses, findings verified) found and fixed 13 issues:
  - unannounced export and crop status;
  - the landscape crop layout, and its panel not filling the height;
  - the nav-bar scrim;
  - the `.part` file outside the backup excludes;
  - ML Kit notices shipped on iOS;
  - an unlabeled rename field;
  - a date-dependent test and a flaky render-order test;
  - a duplicate stress test and a duplicated photo generator;
  - an unused parameter.
- **Tests:** 153 unit and widget tests. The device suites (editor, persistence, export, stress) pass on both platforms, with 33 screenshots per platform, including large-text shots 16–18.
- **Trap.** After device test runs, the generated plugin registrant includes `integration_test`, so a release build with `--no-pub` fails to compile. Release builds must run pub.
- **Needs you** (not done here: outward-facing, or needs hardware or a decision):
  - **TestFlight print check:** it needs an upload, a signing team and the final bundle ID (D6).
  - **Release signing:** Android release builds still use the debug key, so a real keystore is needed for the Play Store.
  - **Physical devices:** the §10.4 checklist, including real ML Kit and VisionKit scans, TalkBack/VoiceOver, 20 × 48 MP on a 4 GB phone, and opening PDFs in Acrobat, Drive and Gmail.
  - **Play Data safety:** the form must disclose ML Kit's anonymous diagnostics.
  - **Android SDK licences:** `flutter doctor --android-licenses` is for you to accept.

### M8 OCR ✅ (2026-10-28)
- **Native text recognition** (`recognizeText` on the `folio/native` channel). It reads a page's processed image, which is exactly what the PDF embeds, so line boxes line up with the page. It returns one `{text, box}` per line, with the box normalised from the top-left.
  - **Android:** unbundled ML Kit Latin text recognition (`play-services-mlkit-text-recognition:19.0.2`; the release APK grew only from 20.0 to 20.3 MB). The OCR model is never downloaded at launch. The first use answers `unavailable` and requests the download, and a phone without Play services just gets `unavailable` with no popup. Recognised text is never logged.
  - **iOS:** Vision `VNRecognizeTextRequest` (accurate, with language correction). It works on the Simulator, unlike Vision's document segmentation.
- **Dart:**
  - **`lib/ocr.dart`:** `readText` keeps a session cache keyed by the page-image path, so an edited page is read again. Reads already in progress are shared, and failures are never cached. Lines are grouped into rows for reading order.
  - **Copy text** in the page menu skips the render wait when the page image is current. Its messages are "Text copied", "No text found on this page", "Text recognition isn't available right now…", and "This page couldn't be prepared…" when the page image failed.
- **Searchable PDF:**
  - A per-document **Searchable text** switch in the export sheet (`Document.searchable`, stored in v1 only when on).
  - **Reading:** pages are read in layout order with a 20 s limit each. A failing page just has no text. Cancel works between pages.
  - **Text layer:** `buildSearchablePdf` adds an invisible line of text (mode 3) under each page image. Its size is set from the font's ascent and descent so a selection covers the line, and it is stretched horizontally to the box width.
  - **Font:** Roboto Regular (Apache-2.0, taken from the Flutter SDK, with its licence on the licence page) is subset and embedded with a Unicode map. Characters it can't draw are dropped, and Ω/∆ are folded to their Greek letters because they share glyphs in Roboto.
  - **Size:** compression is on only when there's a text layer, about 7 KB for a dense page. A PDF without text is unchanged.
  - **Fallback (O3):** if a text layer can't be built, or none of its lines can be drawn, the PDF is built without it, and Save says "· without searchable text".
- **Real end-to-end check (iOS Simulator).** A photo of an invoice was imported through the real picker, Searchable text was turned on, and the PDF was saved to Files. `pdftotext` returned exactly "INVOICE 4471 / Harbour Lane Stores / Total due 84.12 / Paid 28 October 2026", with each word within about 2 pt of where it was drawn. `pdffonts` shows Roboto CID TrueType, embedded, with ToUnicode; `pdfimages` shows the page JPEG still passed through.
- **Review** found and fixed 9 issues:
  - Copy text waited for the whole document's renders;
  - Copy text gave a misleading message when the page image had failed;
  - reads already in progress weren't shared;
  - reading order could put an amount before its label;
  - the text layer was uncompressed;
  - Ω/∆ could drop a whole document's text layer;
  - a text layer with no drawn lines was reported as present;
  - two flaws in the Android device test.
- **Tests:** 200 unit and widget tests. The device suites (editor, persistence, export, OCR) pass on both platforms, with 33 screenshots each. The Android emulator can't download ML Kit models, so its OCR test confirms the native call answers `unavailable` and skips the text checks.
- **Not verified:**
  - ML Kit OCR on a real Android phone;
  - Vision on a real iPhone;
  - search inside Acrobat and Preview themselves (checked with poppler instead);
  - multi-column reading order;
  - non-Latin scripts, which are out of scope per PRD O4.

### Release APK for phone testing (2026-10-28)
- `build/app/outputs/flutter-apk/app-release.apk`: universal (arm64-v8a, armeabi-v7a, x86_64), 57.9 MB, version 0.1.0 (1), Android 7.0+ (API 24), signed with the **debug key** (v2), so it sideloads but isn't for the Play Store.
- **Release-only bug found and fixed.** R8 full mode stripped the no-argument constructors of ML Kit's component registrars, which ML Kit creates by reflection. At launch, ML Kit logged `NoSuchMethodException: …Registrar.<init>`, so text recognition could never initialise in a release build. Debug builds don't shrink code, so every device test passed anyway. `android/app/proguard-rules.pro` now keeps them (`-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }`); Flutter's Gradle plugin picks up that file automatically. After the fix the warnings are gone, and the release build still launches the real ML Kit scanner.

