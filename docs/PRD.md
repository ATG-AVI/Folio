# Folio — Product Requirements Document

> "Folio" is a working name; rename it freely. Status: **draft for review**, 2026-10-27.
> Companion: [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## 1. Summary

Folio is a private, on-device document scanner for Android and iOS phones. It turns paper into clean multi-page PDFs that users can save, share or print. Supported originals: pages, receipts, notes, book pages, business cards, ID cards and photos. There is no account and nothing is uploaded.

Scan quality comes from the operating systems' own scanners: **Google ML Kit Document Scanner** on Android and **Apple VisionKit** on iOS. Folio adds everything those scanners lack: a document library, page editing, filters, ID-card layout and PDF export.

## 2. Goals and non-goals

**Goals (v1)**
1. Scan → clean PDF in under 30 seconds for a 1-page document. Few taps, no sign-up.
2. Edge detection, auto-capture and perspective correction on par with Adobe Scan and Microsoft Lens, by using the platform scanners.
3. Reliable multi-page documents. Page order is identical in the editor, the preview and the PDF.
4. Small, legible PDFs: about 150–400 KB per page at the default quality.
5. A persistent local library with search, sort, rename, duplicate, delete and share.
6. Private by default. Files never leave the device unless the user shares or saves them. No analytics.
7. A small, maintainable codebase: at most about 2,000 lines of app code (Dart, Kotlin and Swift), not counting tests.

**Non-goals (v1)**
- Accounts, cloud sync, or a backup service. The storage design allows these later.
- Annotation, signatures, form filling, PDF merging, password-protected PDFs.
- Book-page curve flattening and two-page spread splitting. Neither OS scanner does this; users scan one page at a time.
- Tablet- or desktop-specific layouts. Tablets run the phone layout. No web.
- A custom camera UI. The scanner screen is the OS scanner (Decision D1).
- Copying Adobe branding, assets or exact UI.

## 3. Users and core jobs

| User | Job |
|---|---|
| Student | Scan notes and book pages into one PDF for study or submission. |
| Professional | Scan a signed contract or a receipt and email it as a PDF within a minute. |
| Household admin | Keep IDs, bills and certificates as tidy PDFs that are easy to find by name. |
| Traveller | Scan the front and back of an ID card onto one page for a form. |

## 4. Primary flow

This follows the requested order: **Home → Scan or Import → Crop & Enhance → Review Pages → Export PDF → Save or Share.**

```
Home ─┬─ Scan ──► OS scanner (its review screen = Crop & Enhance) ─┐
      └─ Import ─► gallery ─► Folio Crop & Enhance (swipe pages) ──┴─► Review Pages ─► Export sheet (Preview) ─► Save · Share · Print
```

- **Scan:** the OS scanner's built-in review step is where the user adjusts corners and picks a filter. Pages arrive already cropped.
- **Import:** new pages open in Folio's Crop & Enhance screen. Crop handles start at the detected corners (iOS) or the full image (Android). It has a filter strip and **Apply to all**. **Done** goes to Review Pages.
- Documents are **auto-saved** as soon as pages arrive, so a crash or interruption loses nothing. Backing out of a new document that has no pages discards it.

## 5. Features and requirements

Priority: **P0** = required for v1, **P1** = should ship in v1, **P2** = later or optional.

### 5.1 Capture (P0)
| ID | Requirement |
|---|---|
| C1 | Scan opens the platform scanner. It provides a live edge overlay, auto-capture, a manual shutter, multi-page capture, and a corner-adjust and filter review. Flash: VisionKit ✅. ML Kit's flash toggle is not documented and must be device-verified in M4. If a device lacks it, that is an accepted OS-scanner limitation. |
| C2 | Multi-page capture in one session, plus **Add page → Scan** to append pages to an existing document. |
| C3 | **Import** uses the system photo picker with multi-select on both platforms. No runtime permission is needed. iOS auto-detects document corners (Vision). Android starts with full-image corners for manual adjustment, because Android has no public still-image detector. Android users can also use the gallery button inside the ML Kit scanner, which auto-crops (device-verify). Screenshots, PNG and HEIC are accepted. A file that can't be decoded is skipped with a message. |
| C4 | Scanned and imported pages can be mixed in one document. |
| C5 | Capture feedback: progress text ("Adding 3 of 8…") with **Cancel**. Cancelling stops after the current file and keeps the pages already added. Errors always show a message; they never fail silently. |
| C6 | When the scanner is unavailable (iOS Simulator, iPhone app running on a Mac, no Google Play services, under 1.7 GB RAM, module not yet downloaded), explain this and offer **Import** or **Take photo**. Take photo uses the system camera, followed by manual corners. |
| C7 | Camera permission denied (iOS): explain and offer **Open Settings**. Android needs no camera permission. |
| C8 | No duplicate captures: only one scanner session runs at a time, and the scan buttons are disabled while it runs. |
| C9 | Camera switching is **dropped**. The OS scanners use only the rear camera, which is the right camera for documents (D1). |

### 5.2 Crop & Enhance / page editing (P0)
| ID | Requirement |
|---|---|
| E1 | Manually adjust the 4 crop corners on any page: drag handles, a magnifier loupe, and a block on invalid (non-convex) shapes. **Auto** (detected corners), **Full** and **Reset**. |
| E2 | Perspective correction from the 4 corners. |
| E3 | Rotate in 90° steps. Skew is straightened through the corner crop. |
| E4 | Filters: **Original**, **Enhance** (auto contrast and colour), **Grayscale** and **Black & White** (adaptive threshold), with an **Apply to all** option. Defaults: scanner pages start on Original, because the scanner already enhanced them; imported pages start on Enhance. |
| E5 | **Retake** (scan one page, keeping only the first page captured) or **Replace from gallery** for a single page. Undo is available from the snackbar. |
| E6 | Drag to reorder (also usable with a screen reader), duplicate, and delete pages. Page delete can be undone. |
| E7 | Non-destructive: the source image is kept and edits are stored as parameters, so a page can always go back to Original. |
| E8 | Quality is preserved: the aspect ratio comes from the crop, images are never upscaled, and no EXIF/GPS data appears in output. |

### 5.3 PDF export (P0)
| ID | Requirement |
|---|---|
| X1 | One PDF from all pages, in on-screen order. |
| X2 | Page size: **Fit** (the default; the page is A4 width with the height following the image, and no margins), **A4** or **Letter** (10 mm margins, image centred, landscape page for landscape images). |
| X3 | Quality: **Small**, **Standard** (default) or **High**. The choice is remembered per document. The final file size is shown after export. |
| X4 | Filename = the sanitised document name. The default document name is `Scan 2026-10-27 18.40`. |
| X5 | Preview before export: page-by-page, built from the same layout code as the PDF. |
| X6 | **Save to device** through the Android "Save as" dialog or the iOS Files picker. The system picker handles name conflicts, so nothing is overwritten silently. |
| X7 | **Share** opens the native share sheet. **Print** opens the system print dialog. |
| X8 | The PDF opens correctly in Acrobat, Chrome, Preview, Files, Google Drive and Gmail. |
| X9 | No duplicate exports: buttons are disabled while exporting. **Cancel** discards the partial file. |

### 5.4 Library (P0)
| ID | Requirement |
|---|---|
| L1 | Home lists documents with a thumbnail (first page), name, page count and modified date. |
| L2 | Search by name: instant, case-insensitive substring match. |
| L3 | Sort by **Recent** (default) or **Name**. |
| L4 | Rename, duplicate, delete (with a confirmation dialog) and share as PDF. |
| L5 | Open a document to review, edit, add pages or export. |
| L6 | Documents persist across restarts. Writes are crash-safe, so a document is never left half-written. A damaged document shows as "Can't open" (Delete or Keep) and is never deleted automatically. |
| L7 | The storage layout (a folder per document plus a JSON manifest) means cloud sync can be added later without a rewrite. |

### 5.5 ID cards (P1)
| ID | Requirement |
|---|---|
| I1 | A dedicated **ID card** entry with a guided, two-step flow. The guide reads "Front side", then the scanner (1 page), then "Now flip the card", then the scanner (1 page). Cancelling returns to the guide. If the scanner is unavailable, the user picks the front and the back from the gallery instead. |
| I2 | Both sides go on one page: A4 or Letter as chosen, with Fit treated as A4. Each side is centred and the two are stacked with a 12 mm gap. A side whose long/short ratio is within ±6 % of 1.586 (ID-1, in either orientation) is printed with its long edge at 85.6 mm, its real size. Otherwise both sides share one scale, so that the larger long edge is 85.6 mm. If the stack is taller than the printable area, both sides are scaled down equally. No fixed card size or orientation is assumed. |
| I3 | Each side can still be re-cropped, rotated, filtered, swapped (by reordering) or retaken in Review Pages. |
| I4 | Sensitive content never appears in logs. There is no analytics. |

### 5.6 OCR and searchable PDF (P2, separate milestone M8)
| ID | Requirement |
|---|---|
| O1 | On-device text recognition per page: ML Kit Text Recognition on Android, Apple Vision on iOS. |
| O2 | "Copy text" for a page. |
| O3 | An optional searchable PDF, with an invisible text layer under each page image. If the text layer fails, the PDF is exported without it rather than failing. |
| O4 | Latin script first. Other scripts are scoped separately because of font and model size. |

### 5.7 Look and feel (P0)
- Material 3 with a custom seed colour. Light and dark themes follow the system.
- Calm, minimal chrome. The pages themselves are the visual focus. Motion is subtle: a hero transition from thumbnail to editor, and fades of about 200 ms.
- Designed states: empty, loading, error, permission denied, scanner unavailable, damaged document, missing page image, and imports that could not be added.
- Accessible: touch targets of at least 48 dp, semantic labels on every icon button, text contrast of at least 4.5:1, text scaling up to 200 % without clipping, and screen-reader page reordering.
- Responsive from 360 dp wide upwards, edge-to-edge (Android 16).

## 6. Non-functional requirements

| Area | Target |
|---|---|
| Speed | Pages visible within 1 s after the scanner closes (5 pages). Edits re-render in the background, within 1.5 s per page on a mid-range phone. Exporting 20 already-rendered pages takes under 5 s. |
| Memory | No out-of-memory crash when importing 20 photos of 48 MP on a 4 GB Android phone **and** a 4 GB iPhone. Images are processed one at a time. |
| Size | The app adds under 5 MB over a blank Flutter app, not counting OCR. |
| Privacy | Folio's own code makes no network calls. No analytics or crash SDKs. Image paths and content are never logged. OS cloud backup is excluded (D4). Store disclosure: on Android, ML Kit sends anonymous usage metadata, never images. |
| Reliability | One scan or export runs at a time. Temporary files are cleaned up at startup. After Android kills the process during a scan, photo capture or import, the pages are recovered into a "Recovered scan" document. |
| Platforms | Android 7.0+ (API 24); the scanner needs Google Play services, with a fallback when they are missing. iOS 15+. Phones are the target; tablets run the same layout. |

## 7. Decisions for the product owner

| ID | Decision | Recommendation |
|---|---|---|
| D1 | Scanner UI: use the OS scanners (best quality, small code; cannot be themed, rear camera only), or build a custom camera on OpenCV (themeable, about 1,500 more lines, several MB larger, worse detection). | **OS scanners** |
| D2 | Flutter SDK: pin 3.47.8 side-by-side (FVM) and leave the global 3.41.8 used by ThisKrit untouched, or build on 3.41.8 with older package versions. | **Pin 3.47.8 with FVM** |
| D3 | State management: plain Flutter (`ChangeNotifier`), or Riverpod. | **Plain Flutter** |
| D4 | Should OS backups include scans, including ID cards? **Exclude**: private, but documents don't move to a new phone. **Allow**: iCloud backup on iOS. On Android, Google Drive backup stops once app data passes 25 MB, so in practice only device-to-device transfer applies. | **Exclude** ("Export all" can be added later) |
| D5 | OCR and searchable PDF: in v1, or as a follow-up milestone. | **Follow-up (M8)** |
| D6 | App name, bundle ID and project location. Placeholders today: `~/Desktop/Folio`, `com.folio.scan`. | — |

## 8. Release acceptance criteria

1. On a physical Android phone (with Play services) and a physical iPhone: scan 3 pages, reorder them, set one page to B&W, export, and open the PDF in another app. No crash, and the page order matches the screen.
2. Each platform scans these and gets legible, correctly proportioned output: an A4 letter, a long receipt, a single book page, a business card, a 6×4 photo and an ID card (front and back).
3. Importing 20 gallery images of 48 MP causes no out-of-memory crash on a 4 GB Android phone or a 4 GB iPhone.
4. Documents survive killing the app and restarting it. Rename, duplicate and delete persist.
5. A Standard-quality A4 PDF of a text page is legible at 100 % zoom and is at most 400 KB per page. Output contains no EXIF/GPS data.
6. Every state in §5.7 has a designed screen, checked by screenshots.
7. `flutter analyze` reports zero issues. Unit, widget and integration tests pass. Debug Android and iOS builds compile. The device checklist (plan §10.4) is signed off.
