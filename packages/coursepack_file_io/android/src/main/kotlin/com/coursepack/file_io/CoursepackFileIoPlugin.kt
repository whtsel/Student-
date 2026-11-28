package com.coursepack.file_io

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/**
 * Provides system-level file picking and saving for the CoursePack licence
 * generator using the Storage Access Framework. No storage permission is
 * required: the user picks a document provider and the app reads or writes
 * through the returned [Uri] with the [android.content.ContentResolver].
 */
class CoursepackFileIoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null

    private var pickLauncher: ActivityResultLauncher<Intent>? = null
    private var saveLauncher: ActivityResultLauncher<Intent>? = null

    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickPath: Boolean = false
    private var pendingSave: Pair<MethodChannel.Result, String>? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.coursepack/file_io")
        channel.setMethodCallHandler(this)
        attachActivity()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.activity = binding.activity
        attachActivity()
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        this.activity = binding.activity
        attachActivity()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    private fun attachActivity() {
        val current = activity ?: return
        if (current !is ComponentActivity) return
        if (pickLauncher == null) {
            pickLauncher = current.registerForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                val pending = pendingPick
                pendingPick = null
                val uri = result.data?.data
                if (pending == null || uri == null) {
                    pending?.success(null)
                    return@registerForActivityResult
                }
                if (pendingPickPath) {
                    pendingPickPath = false
                    pending.success(copyToTempFile(uri))
                } else {
                    pending.success(readText(uri))
                }
            }
        }
        if (saveLauncher == null) {
            saveLauncher = current.registerForActivityResult(
                ActivityResultContracts.StartActivityForResult(),
            ) { result ->
                val pending = pendingSave
                pendingSave = null
                if (pending != null) {
                    val (callback, text) = pending
                    val uri = result.data?.data
                    if (uri == null) {
                        callback.success(null)
                    } else {
                        writeText(uri, text)
                        callback.success(uri.toString())
                    }
                }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val method = call.method
        if (method == "pickTextFile") {
            pendingPick = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("text/*", "application/json", "application/octet-stream", "*/*"),
                )
            pickLauncher?.launch(intent)
                ?: result.error("no_activity", "The file picker is not available yet.", null)
        } else if (method == "pickFilePath") {
            pendingPick = result
            pendingPickPath = true
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("application/octet-stream", "*/*"),
                )
            pickLauncher?.launch(intent)
                ?: result.error("no_activity", "The file picker is not available yet.", null)
        } else if (method == "saveTextFile") {
            val filename = call.argument<String>("filename").orEmpty()
            val text = call.argument<String>("text").orEmpty()
            pendingSave = Pair(result, text)
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .putExtra(Intent.EXTRA_TITLE, filename)
                .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("*/*"))
            saveLauncher?.launch(intent)
                ?: result.error("no_activity", "The file saver is not available yet.", null)
        } else {
            result.notImplemented()
        }
    }

    private fun readText(uri: Uri): String {
        val current = activity ?: throw FileNotFoundException("No activity to read from.")
        return current.contentResolver.openInputStream(uri)
            ?.use { String(it.buffered().readBytes(), Charsets.UTF_8) }
            ?: throw FileNotFoundException("Cannot read $uri.")
    }

    private fun writeText(uri: Uri, text: String) {
        val current = activity ?: throw FileNotFoundException("No activity to write to.")
        current.contentResolver.openOutputStream(uri, "wt")
            ?.use { it.write(text.toByteArray()) }
            ?: throw FileNotFoundException("Cannot write $uri.")
    }

    /**
     * Copies the content at [uri] to a temporary file in the app cache and
     * returns its absolute path. Content URIs returned by the Storage Access
     * Framework cannot be read directly by Dart's [java.io.File], so binary
     * files (e.g. an `.enc` video) are staged to a real path first.
     */
    private fun copyToTempFile(uri: Uri): String {
        val current = activity ?: throw FileNotFoundException("No activity to read from.")
        val temp = java.io.File.createTempFile(
            "coursepack-pick",
            ".tmp",
            current.cacheDir,
        )
        current.contentResolver.openInputStream(uri)
            ?.use { input ->
                temp.outputStream().use { output -> input.copyTo(output) }
            }
            ?: throw FileNotFoundException("Cannot read $uri.")
        return temp.absolutePath
    }
}
