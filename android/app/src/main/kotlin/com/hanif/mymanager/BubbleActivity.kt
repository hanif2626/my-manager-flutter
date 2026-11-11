package com.hanif.mymanager

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * বাবলের ভাসমান প্যানেল — এখন একটা আসল Activity (পথ B, ২০২৬-১১-১১)।
 *
 * আগে প্যানেলটা BubbleService-এর overlay উইন্ডোতে FlutterView হিসেবে
 * চলত — Service-এর উইন্ডোতে Activity-context, lifecycle, সঠিক
 * attach/detach ক্রম কিছুই থাকে না, তাতেই ভেতরের বাটন/টাচ অনিয়মিত
 * হতো (গবেষণা: MyManager-Floating-Bubble-Fix-Plan-BN.md)। এখন:
 * - ডট আর বন্ধ-চিহ্ন আগের মতোই BubbleService-এর নেটিভ overlay।
 * - ডটে ট্যাপ করলে এই Activity খোলে — স্বচ্ছ থিম, ছোট ভাসমান
 *   উইন্ডোর মাপ (আগের প্যানেলের হুবহু একই জ্যামিতি), নিজের engine-এ
 *   `bubbleMain()` (পুরো অ্যাপ)।
 * - Activity বলে lifecycle, কিবোর্ড/IME, Back বাটন, ডায়ালগ/শিট —
 *   সব স্বাভাবিক; এমনকি biometric-ও এখানে চলতে পারে
 *   (FlutterFragmentActivity)।
 *
 * অবস্থা জানানো: onCreate/onResume/onPause/onDestroy BubbleService-কে
 * intent পাঠায় — সার্ভিস তাতেই বোঝে প্যানেল আছে/দেখা যাচ্ছে কি না,
 * আর ডটকে উইন্ডোর উপরে বসায়/ফিরিয়ে নেয়।
 */
class BubbleActivity : FlutterFragmentActivity() {

    companion object {
        const val ACTION_CLOSE = "com.hanif.mymanager.bubble.CLOSE_PANEL"
        private const val PANEL_CHANNEL = "com.hanif.mymanager/bubble-panel"
    }

    override fun getDartEntrypointFunctionName(): String = "bubbleMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == ACTION_CLOSE) {
            // ডট-ট্যাপে বন্ধের সংকেত নিয়ে তৈরি হলেই শেষ (পুরনো
            // instance না থাকলে এটাই পরিষ্কার অবস্থা ধরে রাখে)।
            finish()
            return
        }
        applyFloatingWindow()
        notifyService(BubbleService.ACTION_PANEL_OPENED)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_CLOSE) finish()
    }

    override fun onResume() {
        super.onResume()
        notifyService(BubbleService.ACTION_PANEL_RESUMED)
    }

    override fun onPause() {
        notifyService(BubbleService.ACTION_PANEL_PAUSED)
        super.onPause()
    }

    override fun onDestroy() {
        notifyService(BubbleService.ACTION_PANEL_CLOSED)
        super.onDestroy()
    }

    private fun notifyService(action: String) {
        // বাবল বন্ধ হয়ে গেলে (enabled=false) সার্ভিসকে অযথা জাগিও না।
        if (!BubbleControl.isBubbleEnabled(applicationContext)) return
        try {
            startService(
                Intent(applicationContext, BubbleService::class.java).apply {
                    this.action = action
                },
            )
        } catch (_: Exception) {
        }
    }

    /** আগের overlay প্যানেলের হুবহু একই জ্যামিতি: পাশে ৩২dp ফাঁক, উপরে ১১০dp, নিচে ১১০dp। */
    private fun applyFloatingWindow() {
        val (sw, sh) = screenSize()
        val attrs = window.attributes
        attrs.width = sw - dp(64)
        attrs.height = sh - dp(220)
        attrs.gravity = Gravity.TOP or Gravity.START
        attrs.x = dp(32)
        attrs.y = dp(110)
        attrs.dimAmount = 0f
        window.attributes = attrs
        // বাইরের টাচ নিচের অ্যাপে যাবে (আগের প্যানেলের মতোই)।
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScreenTimeBridge.register(flutterEngine, applicationContext)
        JobNotifBridge.register(flutterEngine, applicationContext)
        // বাবল নিয়ন্ত্রণ — MainActivity-র মতোই, তবে এখানে Activity
        // থাকায় সেটিংস খোলাটা Activity-সংস্করণেই হয়।
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
                    "stopBubble" -> {
                        BubbleControl.stopBubble(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // অ্যাপ খোলা / ডায়াল / লিংক (MainActivity-র মতোই)।
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
        // প্যানেল নিয়ন্ত্রণ (Dart-এর BubbleWindow) — আগে এটা
        // Service-এর engine-এ ছিল, এখন Activity-র engine-এ।
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PANEL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hidePanel" -> {
                        finish()
                        result.success(true)
                    }
                    "closeBubble" -> {
                        BubbleControl.stopBubble(applicationContext)
                        finish()
                        result.success(true)
                    }
                    "openApp" -> {
                        openMainApp(call.argument<String>("target"))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun openMainApp(target: String?) {
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            // গন্তব্য থাকলে MainActivity সেটা Dart-কে দেবে — অ্যাপ
            // পুরনো পেজে না খুলে সোজা সেই পেজে যাবে।
            if (target != null) putExtra(MainActivity.EXTRA_BUBBLE_TARGET, target)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
        finish()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun screenSize(): Pair<Int, Int> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            bounds.width() to bounds.height()
        } else {
            @Suppress("DEPRECATION")
            val dm = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getMetrics(dm)
            dm.widthPixels to dm.heightPixels
        }
    }
}
