package com.folio.folio

import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.util.PathUtils
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

// Arbitrary, but must not collide with image_picker's codes: plugin results arrive through the same hook.
private const val REQUEST_SCAN = 0xF011
private const val REQUEST_SAVE = 0xF012
private var prefetched = false
private val io = Executors.newSingleThreadExecutor() // Per process: a per-Activity pool leaks a thread on every recreation.
// Per process, and lazy so people who never use OCR never touch it. Unbundled: the model is a Play services download.
private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

/** Native bridge for the ML Kit document scanner and text recognition (plan §6). iOS lives in AppDelegate. */
class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pending: MethodChannel.Result? = null
    private var saving: MethodChannel.Result? = null
    private var savingFrom: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "folio/native")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "scan" -> scan(call.argument<Int>("pageLimit"), result)
                "detectCorners" -> result.success(null) // ML Kit gives no corners; the user drags them.
                "saveAs" -> saveAs(call.argument<String>("path"), call.argument<String>("name"), result)
                "recognizeText" -> recognizeText(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
        // Start the module download at first launch so the first scan doesn't wait. Only with working Play
        // services: otherwise the request posts a "Get Google Play services" dialog or notification on every
        // cold start, while scan() already reports 'unavailable' and the photo fallback takes over.
        if (!prefetched && GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) == ConnectionResult.SUCCESS) {
            prefetched = true
            try {
                ModuleInstall.getClient(applicationContext).installModules(ModuleInstallRequest.newBuilder().addApi(scanner(null)).build())
            } catch (_: Exception) {}
        }
    }

    private fun scanner(pageLimit: Int?) = GmsDocumentScanning.getClient(
        GmsDocumentScannerOptions.Builder()
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .apply { if (pageLimit != null) setPageLimit(pageLimit) }
            .build(),
    )

    private fun scan(pageLimit: Int?, result: MethodChannel.Result) {
        pending?.success(emptyList<String>()) // A new scan supersedes a stale one.
        pending = result
        fun unavailable(e: Exception) {
            if (pending !== result) return
            pending = null
            result.error("unavailable", e.message, null)
        }
        try {
            scanner(pageLimit).getStartScanIntent(this)
                .addOnSuccessListener {
                    if (pending !== result) return@addOnSuccessListener
                    try {
                        startIntentSenderForResult(it, REQUEST_SCAN, null, 0, 0, 0)
                    } catch (e: Exception) {
                        unavailable(e)
                    }
                }
                .addOnFailureListener(::unavailable)
        } catch (e: Exception) {
            unavailable(e)
        }
    }

    // One {text, box} per line of a rendered page, box = [left, top, right, bottom] in 0..1 from the top left. Nothing here logs text or paths.
    private fun recognizeText(path: String?, result: MethodChannel.Result) {
        if (path == null) return result.error("failed", "recognizeText needs a path", null)
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(applicationContext) != ConnectionResult.SUCCESS) {
            return result.error("unavailable", "Google Play services is not usable", null) // No install request: it would pop a "Get Google Play services" dialog.
        }
        val installer = ModuleInstall.getClient(applicationContext)
        fun unavailable(why: String?) {
            // Ask for the model now, fire-and-forget, so the next try works. A missing model must never pass for "no text".
            try { installer.installModules(ModuleInstallRequest.newBuilder().addApi(recognizer).build()) } catch (_: Exception) {}
            result.error("unavailable", why, null)
        }
        fun recognize() = io.execute {
            val image = try {
                InputImage.fromFilePath(applicationContext, Uri.fromFile(File(path)))
            } catch (e: Throwable) { // Includes OutOfMemoryError: OCR must never take the app down. The class name only: messages carry paths.
                return@execute runOnUiThread { result.error("failed", e.javaClass.simpleName, null) }
            }
            recognizer.process(image) // Listeners run on the main thread.
                .addOnSuccessListener { text ->
                    fun unit(v: Int, size: Int) = (v.toDouble() / size).coerceIn(0.0, 1.0)
                    // Limit: exact top then left, so same-row lines a few px apart can swap and columns interleave. Band the rows if Copy text reads wrong.
                    result.success(
                        text.textBlocks.flatMap { it.lines }
                            .mapNotNull { line -> line.boundingBox?.let { line.text to it } }
                            .filter { it.first.isNotBlank() }
                            .sortedWith(compareBy({ it.second.top }, { it.second.left }))
                            .map { (t, b) ->
                                mapOf("text" to t, "box" to listOf(unit(b.left, image.width), unit(b.top, image.height), unit(b.right, image.width), unit(b.bottom, image.height)))
                            },
                    )
                }
                .addOnFailureListener { e ->
                    if (e is MlKitException && e.errorCode == MlKitException.UNAVAILABLE) unavailable(e.message) else result.error("failed", e.javaClass.simpleName, null)
                }
        }
        try {
            installer.areModulesAvailable(recognizer)
                .addOnSuccessListener { if (it.areModulesAvailable()) recognize() else unavailable("The text model is not downloaded yet") }
                .addOnFailureListener { unavailable(it.message) }
        } catch (e: Exception) {
            result.error("failed", e.javaClass.simpleName, null)
        }
    }

    private fun saveAs(path: String?, name: String?, result: MethodChannel.Result) {
        if (path == null || name == null) return result.error("failed", "saveAs needs a path and a name", null)
        saving?.success(false) // A new save supersedes a stale one.
        saving = result
        savingFrom = path
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/pdf")
            startActivityForResult(intent.putExtra(Intent.EXTRA_TITLE, name), REQUEST_SAVE)
        } catch (e: Exception) { // No picker app (ActivityNotFoundException) or no activity to launch from.
            saving = null
            result.error("unavailable", e.message, null)
        }
    }

    private fun discard(uri: Uri) {
        try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) {}
    }

    // The picker's brand-new file is empty; an "Overwrite" pick returns the user's existing document. Unknown size = not empty.
    private fun isEmpty(uri: Uri) = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { it.moveToFirst() && !it.isNull(0) && it.getLong(0) == 0L } ?: false
    } catch (_: Exception) {
        false
    }

    private fun saved(uri: Uri?) {
        val result = saving
        val from = savingFrom
        saving = null
        savingFrom = null
        when {
            uri == null -> result?.success(false) // Cancelled.
            // Activity was recreated: drop the empty file the picker made, never an existing file the user chose to overwrite.
            result == null || from == null -> io.execute { if (isEmpty(uri)) discard(uri) }
            else -> io.execute {
                val fresh = isEmpty(uri) // Before opening: "wt" truncates, after which an overwritten original looks new.
                val failure = try {
                    File(from).inputStream().use { src ->
                        // "wt": plain openOutputStream is "w", which doesn't truncate, so a shorter PDF would keep the old file's tail.
                        checkNotNull(contentResolver.openOutputStream(uri, "wt")) { "Could not open the chosen file" }.use { src.copyTo(it) }
                    }
                    null
                } catch (e: Exception) {
                    // No half-written PDF left behind. An overwritten original may already be truncated and can't be restored, but it's the user's file: keep it.
                    if (fresh) discard(uri)
                    e
                }
                runOnUiThread { if (failure != null) result.error("failed", failure.message, null) else result.success(true) }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data) // Always: image_picker needs its own results.
        if (requestCode == REQUEST_SAVE) {
            saved(if (resultCode == RESULT_OK) data?.data else null)
            return
        }
        if (requestCode != REQUEST_SCAN) return
        val result = pending
        pending = null
        val pages = if (resultCode == RESULT_OK && data != null) {
            GmsDocumentScanningResult.fromActivityResultIntent(data)?.pages.orEmpty()
        } else {
            emptyList() // Cancelled.
        }
        io.execute {
            val moved = mutableListOf<String>()
            val failure = try {
                val inbox = File(PathUtils.getFilesDir(this), "inbox").apply { mkdirs() }
                val stamp = System.currentTimeMillis() // Lexical order = page order, scans by time.
                pages.forEachIndexed { i, page ->
                    val from = File(page.imageUri.path!!)
                    val to = File(inbox, "scan-$stamp-${i.toString().padStart(3, '0')}.jpg")
                    if (!from.renameTo(to)) {
                        // Copy outside the inbox, then rename: recovery never sees a half-written page.
                        val part = File(PathUtils.getFilesDir(this), to.name + ".part")
                        try {
                            from.copyTo(part, overwrite = true)
                            if (!part.renameTo(to)) throw IOException("Could not move ${part.name} into the inbox")
                        } catch (e: Exception) {
                            part.delete()
                            throw e
                        }
                        from.delete()
                    }
                    moved += to.path
                }
                null
            } catch (e: Exception) {
                e // Whatever was moved stays in the inbox and is recovered at the next launch.
            }
            runOnUiThread {
                when {
                    result == null -> if (moved.isNotEmpty()) channel.invokeMethod("inboxReady", null) // Activity was recreated.
                    failure != null -> result.error("failed", failure.message, null)
                    else -> result.success(moved)
                }
            }
        }
    }
}
