package com.example.cho_app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.cho_app/abdm"
    private val WAKE_CHANNEL = "cho_app/wake_lock"

    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Wake-lock channel (keeps screen on during video consultation) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            val pm = getSystemService(POWER_SERVICE) as PowerManager
                            wakeLock = pm.newWakeLock(
                                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                                        PowerManager.ACQUIRE_CAUSES_WAKEUP,
                                "cho_app:VideoConsultation"
                            )
                            wakeLock?.acquire(30 * 60 * 1000L) // max 30 min
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("WAKE_ERROR", e.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            wakeLock?.let { if (it.isHeld) it.release() }
                            wakeLock = null
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("WAKE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAbdmApp" -> {
                    val url = call.argument<String>("url")
                    val packageName = call.argument<String>("packageName")
                    if (url == null || packageName == null) {
                        result.error("INVALID_ARGS", "url and packageName are required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        intent.setPackage(packageName)
                        val pm = packageManager
                        if (intent.resolveActivity(pm) != null) {
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.error("NOT_INSTALLED", "ABDM App ($packageName) not installed", null)
                        }
                    } catch (e: Exception) {
                        result.error("LAUNCH_ERROR", e.message, null)
                    }
                }
                "isAppInstalled" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("INVALID_ARGS", "packageName is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        packageManager.getPackageInfo(packageName, 0)
                        result.success(true)
                    } catch (e: PackageManager.NameNotFoundException) {
                        result.success(false)
                    }
                }
                "openPlayStore" -> {
                    val packageName = call.argument<String>("packageName") ?: "in.ndhm.phr"
                    try {
                        val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$packageName"))
                        startActivity(marketIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val webIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$packageName"))
                            startActivity(webIntent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("STORE_ERROR", e2.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
