package com.hanif.mymanager

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Dart থেকে FLAG_SECURE চালু/বন্ধ করার চ্যানেল — ভল্ট/ডকস/অটোফিল
 * পিকারের মতো সংবেদনশীল স্ক্রিনে স্ক্রিনশট ও টাস্ক-সুইচার
 * থাম্বনেইলে সিক্রেট যাতে না দেখা যায়। (SecureScreen দেখো।)
 */
object WindowFlags {
    const val CHANNEL = "com.hanif.mymanager/window"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val secure = call.arguments as? Boolean ?: false
                    if (secure) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
