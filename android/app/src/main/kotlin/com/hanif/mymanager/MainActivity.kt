package com.hanif.mymanager

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by the
// local_auth plugin for its biometric/PIN prompt to work.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        const val EXTRA_BUBBLE_TARGET = "bubble_target"
    }

    // বাবল থেকে আসা গন্তব্য — Dart একবার পড়ে নিলেই শেষ।
    private var pendingBubbleTarget: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingBubbleTarget = intent?.getStringExtra(EXTRA_BUBBLE_TARGET)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingBubbleTarget = intent.getStringExtra(EXTRA_BUBBLE_TARGET)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScreenTimeBridge.register(flutterEngine, applicationContext)
        WindowFlags.register(flutterEngine, this)
        // ভাসমান বাবল (BubbleControl): চালু/বন্ধ, ওভারলে অনুমতি।
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BubbleControl.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOverlayGranted" -> result.success(BubbleControl.isOverlayGranted(applicationContext))
                    "isBubbleEnabled" -> result.success(BubbleControl.isBubbleEnabled(applicationContext))
                    "isBubbleRunning" -> result.success(BubbleControl.isBubbleRunning())
                    "openOverlaySettings" -> {
                        BubbleControl.openOverlaySettings(this)
                        result.success(true)
                    }
                    "startBubble" -> result.success(BubbleControl.startBubble(applicationContext))
                    "takeBubbleTarget" -> {
                        val t = pendingBubbleTarget
                        pendingBubbleTarget = null
                        result.success(t)
                    }
                    "stopBubble" -> {
                        BubbleControl.stopBubble(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // চাকরির অ্যাপের নোটিফিকেশন ট্র্যাক (শুধু বেছে দেওয়া অ্যাপ)।
        JobNotifBridge.register(flutterEngine, applicationContext)
        // চাকরি হাব থেকে SmartStudyBD খোলা / সার্কুলারের লিংক খোলা।
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.hanif.mymanager/launcher")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchApp" -> {
                        val pkg = call.argument<String>("package")
                        val intent = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                        if (intent != null) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "dial" -> {
                        val number = call.argument<String>("number")
                        try {
                            val i = Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(number ?: "")))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        try {
                            val i = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
