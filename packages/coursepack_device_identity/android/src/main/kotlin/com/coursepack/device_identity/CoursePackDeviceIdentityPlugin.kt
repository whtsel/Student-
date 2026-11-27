package com.coursepack.device_identity

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class CoursePackDeviceIdentityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.coursepack/device_identity")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "readComponents") {
            result.notImplemented()
            return
        }

        try {
            val parts = mutableListOf<String>()
            val androidId = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID,
            )
            if (!androidId.isNullOrBlank()) parts.add("android:$androidId")

            val appId = context.packageName
            if (appId.isNotBlank()) parts.add("app-id:$appId")

            certificateSha256()?.let { parts.add("cert:$it") }
            if (Build.FINGERPRINT.isNotBlank()) parts.add("build:${Build.FINGERPRINT}")

            result.success(parts.joinToString("|"))
        } catch (error: Exception) {
            result.error("device_identity_failed", error.message, null)
        }
    }

    private fun certificateSha256(): String? {
        val packageInfo: PackageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNATURES,
            )
        }

        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures
        }
        val certificate = signatures?.firstOrNull()?.toByteArray() ?: return null
        return MessageDigest.getInstance("SHA-256")
            .digest(certificate)
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
