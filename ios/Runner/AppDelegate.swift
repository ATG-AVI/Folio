import AVFoundation
import Flutter
import UIKit
import Vision
import VisionKit

/// Where Dart's inbox recovery looks: <Application Support>/inbox.
private let inbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("inbox")

private func failure(_ code: String) -> FlutterError { FlutterError(code: code, message: nil, details: nil) }

/// Hosts VisionKit's camera and owns the pending result, so a stale scan can never answer a newer one.
/// A host because VNDocumentCameraViewController can't be subclassed: its init returns an instance of a
/// private class, so a subclass's stored properties and overrides would never run.
private final class ScanHost: UIViewController, VNDocumentCameraViewControllerDelegate {
  var reply: FlutterResult?
  var limit: Int?
  private var cameraShown = false
  private var closed = false

  /// Takes the result before any dismissal, so a lifecycle callback cannot resolve it a second time.
  func take() -> FlutterResult? {
    defer { reply = nil }
    return reply
  }

  /// Dismissing from the presenter removes the host and the camera above it together.
  func close() {
    guard !closed else { return }
    closed = true
    presentingViewController?.dismiss(animated: true)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard cameraShown else {
      cameraShown = true
      let camera = VNDocumentCameraViewController()
      camera.delegate = self
      camera.modalPresentationStyle = .fullScreen
      present(camera, animated: true)
      return
    }
    // A .fullScreen presentation's dismissal makes its presenter appear again, so the camera is gone.
    // VisionKit may never call its delegate when Done is tapped right after capture (plan §6).
    take()?([String]())
    close()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Presenting the camera .fullScreen also disappears the host; only a real exit resolves.
    guard presentedViewController == nil else { return }
    take()?([String]())
  }

  // Last resort (e.g. something dismissed the whole stack): Dart must never wait forever.
  deinit { reply?([String]()) }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    let reply = take()
    close()
    reply?([String]())
  }

  func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
    let reply = take()
    close()
    reply?(failure("failed"))
  }

  func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
    let reply = take()
    close()
    guard let reply else { return }
    let count = min(scan.pageCount, limit ?? scan.pageCount)
    DispatchQueue.global().async {
      do {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let paths = try (0..<count).map { i -> String in
          try autoreleasepool {
            let file = inbox.appendingPathComponent(String(format: "scan-%ld-%03ld.jpg", stamp, i))
            guard let jpeg = scan.imageOfPage(at: i).jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: file)
            return file.path
          }
        }
        DispatchQueue.main.async { reply(paths) }
      } catch {
        // Pages already written stay in the inbox; Dart recovers them at next launch.
        DispatchQueue.main.async { reply(failure("failed")) }
      }
    }
  }
}

/// Answers the Files picker exactly once. AppDelegate keeps it alive: UIKit holds a picker's delegate weakly.
private final class SaveDelegate: NSObject, UIDocumentPickerDelegate {
  private var done: ((Bool) -> Void)?
  init(done: @escaping (Bool) -> Void) { self.done = done }

  func finish(_ saved: Bool) {
    let done = done
    self.done = nil
    done?(saved)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(true) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private weak var scanner: ScanHost?
  private var saving: SaveDelegate?

  private static let canScan: Bool = {
    #if targetEnvironment(simulator)
    return false
    #else
    return VNDocumentCameraViewController.isSupported && !ProcessInfo.processInfo.isiOSAppOnMac
    #endif
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // library/ and inbox/ hold the user's scans; keep them out of iCloud backups (D4).
    var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    try? support.setResourceValues(excluded)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FolioNative") else { return }
    FlutterMethodChannel(name: "folio/native", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [self] call, result in
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "scan": scan(limit: args?["pageLimit"] as? Int, from: registrar.viewController, result)
        case "detectCorners": detectCorners(path: args?["path"] as? String, result)
        case "recognizeText": recognizeText(path: args?["path"] as? String, result)
        case "saveAs": saveAs(path: args?["path"] as? String, from: registrar.viewController, result)
        case "openSettings":
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) { _ in result(nil) }
        default: result(FlutterMethodNotImplemented)
        }
      }
  }

  private func scan(limit: Int?, from root: UIViewController?, _ result: @escaping FlutterResult) {
    scanner?.take()?([String]())
    guard Self.canScan else { return result(failure("unavailable")) }
    let camera = AVCaptureDevice.authorizationStatus(for: .video)  // .notDetermined: VisionKit prompts itself.
    guard camera != .denied, camera != .restricted else { return result(failure("denied")) }
    guard let top = topmost(root) else { return result(failure("failed")) }
    let host = ScanHost()
    host.view.backgroundColor = .clear
    host.modalPresentationStyle = .overFullScreen
    host.reply = result
    host.limit = limit
    scanner = host
    top.present(host, animated: false)  // The host presents the camera itself, once it has appeared.
  }

  private func topmost(_ root: UIViewController?) -> UIViewController? {
    var top = root
    while let next = top?.presentedViewController { top = next }
    return top
  }

  /// The exported file keeps the name of the file at `path` (Dart names it), so Android's `name` is unused here.
  private func saveAs(path: String?, from root: UIViewController?, _ result: @escaping FlutterResult) {
    saving?.finish(false)
    guard let path, let top = topmost(root) else { return result(failure("failed")) }
    let delegate = SaveDelegate { [weak self] saved in
      self?.saving = nil
      result(saved)
    }
    let picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: path)], asCopy: true)
    picker.delegate = delegate
    saving = delegate
    top.present(picker, animated: true)
  }

  /// Vision's origin is bottom-left, so y is flipped to match Dart's top-left. Passing the file's EXIF
  /// orientation makes the points land in the upright image.
  private func detectCorners(path: String?, _ result: @escaping FlutterResult) {
    guard let path else { return result(nil) }
    DispatchQueue.global().async {
      let url = URL(fileURLWithPath: path)
      let exif = CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? UInt32
      let request = VNDetectDocumentSegmentationRequest()
      try? VNImageRequestHandler(url: url, orientation: CGImagePropertyOrientation(rawValue: exif ?? 1) ?? .up).perform([request])
      // With no document, Vision still answers: a whole-frame box at confidence 0 (always so on the Simulator).
      let corners = request.results?.first(where: { $0.confidence >= 0.5 }).map { box in
        [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft].flatMap { [Double($0.x), Double(1 - $0.y)] }
      }
      DispatchQueue.main.async { result(corners) }
    }
  }

  /// One entry per recognised line, top-to-bottom then left-to-right, box normalised with a top-left origin
  /// (Vision's is bottom-left, hence the flip). Renders are upright and EXIF-free, so `.up` is right.
  /// Never logs the text or the path (PRD §6).
  private func recognizeText(path: String?, _ result: @escaping FlutterResult) {
    guard let path else { return result(failure("failed")) }
    DispatchQueue.global().async {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      do {
        try VNImageRequestHandler(url: URL(fileURLWithPath: path), orientation: .up).perform([request])
      } catch {
        return DispatchQueue.main.async { result(failure("failed")) }
      }
      let lines = (request.results ?? []).compactMap { line -> (text: String, box: [Double])? in
        guard let text = line.topCandidates(1).first?.string else { return nil }
        let b = line.boundingBox
        return (text, [Double(b.minX), Double(1 - b.maxY), Double(b.maxX), Double(1 - b.minY)])
      }
      .sorted { ($0.box[1], $0.box[0]) < ($1.box[1], $1.box[0]) }
      .map { ["text": $0.text, "box": $0.box] as [String: Any] }
      DispatchQueue.main.async { result(lines) }
    }
  }
}
