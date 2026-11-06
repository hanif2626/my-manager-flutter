package com.hanif.mymanager

import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.max

/**
 * Messenger-এর চ্যাট হেডের মতো ভাসমান বাবল — নিজের ফোরগ্রাউন্ড সার্ভিস।
 *
 * তিনটি আলাদা WindowManager ভিউ, তিনটি আলাদা কাজ — এটাই আগের ব্যর্থতার
 * মূল শিক্ষা। আগের প্লাগইন একটাই Flutter ভিউকে গোল → প্যানেল রিসাইজ
 * করত, আর Flutter-এর ভেতরে ড্র্যাগ করত; তাতেই ট্যাপ-বনাম-ড্র্যাগ দ্বন্দ্ব,
 * রিসাইজ-গ্লিচ আর Vivo-তে আটকে যাওয়া। এখানে:
 * - ডট (dotView): নেটিভ Android ভিউ। ড্র্যাগ, ট্যাপ, কিনারায় স্ন্যাপ —
 *   সব নেটিভে। Flutter-এর সঙ্গে এর কোনো সম্পর্ক নেই, তাই আটকায় না।
 * - ভাসমান উইন্ডো (panelView): আলাদা FlutterView, নিজের FlutterEngine-এ
 *   `bubbleMain()` চালায় — ভেতরে ছোট প্যানেল নয়, পুরো অ্যাপটাই
 *   (MyManagerApp)। ডটে ট্যাপ করলে দেখায়/লুকায়; ডট তখনো স্ক্রিনে
 *   থাকে (উইন্ডোর উপরেও), তাই আবার ট্যাপ করলেই উইন্ডো লুকিয়ে যায়।
 * - বন্ধ-চিহ্ন (dismissView): শুধু ড্র্যাগ করার সময় নিচের মাঝখানে
 *   দেখা যায়। ডটটা তার ওপরে ছাড়লেই বাবল বন্ধ (enabled=false লিখে
 *   সার্ভিস থামে)।
 *
 * কিবোর্ড: ডট FLAG_NOT_FOCUSABLE (নিচের অ্যাপের ফোকাস চুরি করে না),
 * প্যানেল FLAG_NOT_TOUCH_MODAL + ফোকাসেবল (TextField-এ কিবোর্ড আসে,
 * বাইরে ট্যাপ করলে নিচের অ্যাপও টাচ পায়)।
 *
 * ডাটা: উইন্ডোর engine আলাদা isolate — মূল অ্যাপের মেমরি/DB হ্যান্ডল
 * এখানে নেই। উইন্ডোর অ্যাপ নিজে একই SQLite ফাইল খোলে (ছোট লেনদেন),
 * আর মূল অ্যাপ DataSync-এর ২ সেকেন্ডের পোল + resume-চেকে তা ধরে ফেলে —
 * তাই engine-দুটোর মধ্যে কোনো বার্তা পাঠানোর দরকার নেই।
 */
class BubbleService : Service() {

    companion object {
        const val ACTION_START = "com.hanif.mymanager.bubble.START"
        const val ACTION_STOP = "com.hanif.mymanager.bubble.STOP"

        @Volatile
        var isRunning: Boolean = false
            private set

        private const val NOTIF_ID = 1001
        private const val NOTIF_CHANNEL_ID = "my_manager_bubble"
        private const val PANEL_CHANNEL = "com.hanif.mymanager/bubble-panel"
    }

    private lateinit var windowManager: WindowManager
    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var panelChannel: MethodChannel? = null

    private lateinit var dotView: FrameLayout
    private lateinit var dotParams: WindowManager.LayoutParams
    private lateinit var dismissView: FrameLayout
    private lateinit var dismissParams: WindowManager.LayoutParams
    private lateinit var dismissMark: TextView
    private var panelParams: WindowManager.LayoutParams? = null

    private var dotAdded = false
    private var dismissAdded = false
    private var panelAdded = false
    private var panelVisible = false

    // ডটের "বাড়ি" — উইন্ডো খুললে ডট উপরে বসে, লুকালে এখানে ফেরে।
    private var dotHomeX = -1
    private var dotHomeY = -1
    private var dotParked = false

    private var dotSizePx = 0
    private var screenW = 0
    private var screenH = 0

    // ড্র্যাগের অবস্থা — একটাই জেশ্চারে ট্যাপ/ড্র্যাগ/স্ন্যাপ/বন্ধ ঠিক হয়।
    private var downRawX = 0f
    private var downRawY = 0f
    private var downDotX = 0
    private var downDotY = 0
    private var downTime = 0L
    private var dragging = false
    private var overDismiss = false
    private var snapAnimator: ValueAnimator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        // ফোরগ্রাউন্ড নোটিফিকেশন সবার আগে — দেরি করলে সিস্টেম সার্ভিস মেরে ফেলে।
        startForeground(NOTIF_ID, buildNotification())
        // বন্ধ করা অবস্থায় সিস্টেম আবার জাগিয়ে তুললে (START_STICKY) ফিরে যাও।
        if (!BubbleControl.isBubbleEnabled(applicationContext) ||
            !Settings.canDrawOverlays(applicationContext)
        ) {
            stopSelf()
            return
        }
        val (w, h) = screenSize()
        screenW = w
        screenH = h
        dotSizePx = dp(64)
        setupEngine()
        setupDismissView()
        setupDotView()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        snapAnimator?.cancel()
        try {
            if (panelAdded) windowManager.removeView(flutterView)
        } catch (_: Exception) {
        }
        panelAdded = false
        panelVisible = false
        try {
            if (dismissAdded) windowManager.removeView(dismissView)
        } catch (_: Exception) {
        }
        dismissAdded = false
        try {
            if (dotAdded) windowManager.removeView(dotView)
        } catch (_: Exception) {
        }
        dotAdded = false
        try {
            flutterView?.detachFromFlutterEngine()
        } catch (_: Exception) {
        }
        try {
            engine?.destroy()
        } catch (_: Exception) {
        }
        engine = null
        flutterView = null
        panelChannel = null
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    // ── ফোরগ্রাউন্ড নোটিফিকেশন ────────────────────────────────────────

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            "বাবল",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "ভাসমান বাবল চলছে" }
        manager.createNotificationChannel(channel)
        val openIntent = Intent(applicationContext, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val pending = PendingIntent.getActivity(
            applicationContext, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(applicationContext, NOTIF_CHANNEL_ID)
            .setContentTitle("My Manager বাবল চলছে")
            .setContentText("বাবল বন্ধ করতে নিচের ✕ চিহ্নে টেনে নাও")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    // ── Flutter engine (প্যানেল) ───────────────────────────────────────

    private fun setupEngine() {
        try {
            FlutterInjector.instance().flutterLoader()
                .ensureInitializationComplete(applicationContext, null)
        } catch (_: Exception) {
        }
        val eng = FlutterEngine(applicationContext)
        val entrypoint = DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            "bubbleMain",
        )
        eng.dartExecutor.executeDartEntrypoint(entrypoint)
        engine = eng
        // TextureView দিয়ে রেন্ডার — ডিফল্ট SurfaceView ভাসমান উইন্ডোতে
        // ছবি ঠিক আঁকে কিন্তু টাচ ইঞ্জিন পর্যন্ত পৌঁছায় না (z-index /
        // input সমস্যা, v1553-এ ফোনে ধরা পড়েছে)। TextureView সাধারণ
        // ভিউ-হায়ারার্কিতেই থাকে, তাই টাচ স্বাভাবিকভাবে কাজ করে।
        // পারফরম্যান্স একটু কম হতে পারে, কিন্তু কাজ না করা বাবলের
        // চেয়ে একটু ধীরে চলা বাবল ভালো।
        val view = FlutterView(applicationContext, FlutterTextureView(applicationContext))
        view.attachToFlutterEngine(eng)
        flutterView = view
        // DIAGNOSTIC (অস্থায়ী — টাচের সমস্যা ধরা পড়লে তুলে ফেলতে হবে):
        // নেটিভ টাচ প্রোব — উইন্ডোতে টাচ করলে টোস্ট দেখাবে। টোস্ট উঠলে
        // বুঝব টাচ FlutterView পর্যন্ত পৌঁছাচ্ছে; না উঠলে উইন্ডোই
        // টাচ পাচ্ছে না। false ফেরায় — টাচ Flutter-এর কাছেও যায়।
        view.isClickable = true
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        view.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                Log.d("BubbleService", "FlutterView ACTION_DOWN x=" + event.x + " y=" + event.y)
                try {
                    Toast.makeText(
                        applicationContext,
                        "ভিউতে টাচ পৌঁছেছে",
                        Toast.LENGTH_SHORT,
                    ).show()
                } catch (_: Exception) {
                }
            }
            false
        }
        panelChannel = MethodChannel(eng.dartExecutor.binaryMessenger, PANEL_CHANNEL)
            .apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "hidePanel" -> {
                            hidePanel()
                            result.success(true)
                        }
                        "closeBubble" -> {
                            closeBubble()
                            result.success(true)
                        }
                        "openApp" -> {
                            openApp()
                            result.success(true)
                        }
                        // DIAGNOSTIC (অস্থায়ী): Dart থেকে টোস্ট।
                        "showToast" -> {
                            val msg = call.argument<String>("msg") ?: ""
                            try {
                                Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
                            } catch (_: Exception) {
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        // ভেতরে এখন পুরো অ্যাপ চলে — তাই মূল অ্যাপের ইঞ্জিনে যেসব চ্যানেল
        // আছে, সেগুলো বাবলের ইঞ্জিনেও লাগবে, নইলে সেটিংস টগল, স্ক্রিনটাইম,
        // জব নোটিফিকেশন আর অ্যাপ খোলা — কিছুই কাজ করবে না।
        // ScreenTimeBridge/JobNotifBridge শুধু Context নেয় — সরাসরি চলে।
        ScreenTimeBridge.register(eng, applicationContext)
        JobNotifBridge.register(eng, applicationContext)
        // বাবল নিয়ন্ত্রণ (MainActivity-র মতোই, শুধু সেটিংস খোলাটা
        // Service-এর Context দিয়ে — Activity এখানে নেই)।
        MethodChannel(eng.dartExecutor.binaryMessenger, BubbleControl.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOverlayGranted" -> result.success(BubbleControl.isOverlayGranted(applicationContext))
                    "isBubbleEnabled" -> result.success(BubbleControl.isBubbleEnabled(applicationContext))
                    "isBubbleRunning" -> result.success(BubbleControl.isBubbleRunning())
                    "openOverlaySettings" -> {
                        BubbleControl.openOverlaySettingsFromService(applicationContext)
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
        // অ্যাপ খোলা / ডায়াল / লিংক (MainActivity-র মতোই, শুধু
        // applicationContext দিয়ে — Service-এ Activity নেই)।
        MethodChannel(eng.dartExecutor.binaryMessenger, "com.hanif.mymanager/launcher")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchApp" -> {
                        val pkg = call.argument<String>("package")
                        val intent = pkg?.let { applicationContext.packageManager.getLaunchIntentForPackage(it) }
                        if (intent != null) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            applicationContext.startActivity(intent)
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
                            applicationContext.startActivity(i)
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
                            applicationContext.startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── ডট (নেটিভ) ────────────────────────────────────────────────────

    private fun setupDotView() {
        val dot = FrameLayout(applicationContext)
        val bg = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(0xFF6366F1.toInt(), 0xFF8B5CF6.toInt()),
        ).apply {
            shape = GradientDrawable.OVAL
            setStroke(dp(2), 0xFFFFFFFF.toInt())
        }
        dot.background = bg
        val icon = ImageView(applicationContext).apply {
            try {
                setImageDrawable(applicationInfo.loadIcon(packageManager))
            } catch (_: Exception) {
                setImageResource(android.R.drawable.ic_dialog_info)
            }
            scaleType = ImageView.ScaleType.FIT_CENTER
            layoutParams = FrameLayout.LayoutParams(dp(46), dp(46), Gravity.CENTER)
        }
        dot.addView(icon)
        dot.setOnTouchListener { _, event -> handleDotTouch(event) }
        dotView = dot

        val (savedX, savedY) = loadDotPosition()
        dotParams = WindowManager.LayoutParams(
            dotSizePx, dotSizePx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = savedX
            y = savedY
        }
        windowManager.addView(dot, dotParams)
        dotAdded = true
    }

    private fun handleDotTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                snapAnimator?.cancel()
                dragging = false
                overDismiss = false
                downRawX = event.rawX
                downRawY = event.rawY
                downDotX = dotParams.x
                downDotY = dotParams.y
                downTime = event.eventTime
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downRawX
                val dy = event.rawY - downRawY
                if (!dragging &&
                    hypot(dx.toDouble(), dy.toDouble()) >
                    ViewConfiguration.get(applicationContext).scaledTouchSlop
                ) {
                    dragging = true
                    showDismissView()
                }
                if (dragging) {
                    dotParams.x = (downDotX + dx).toInt()
                        .coerceIn(0, max(0, screenW - dotSizePx))
                    dotParams.y = (downDotY + dy).toInt()
                        .coerceIn(0, max(0, screenH - dotSizePx))
                    updateDotLayout()
                    val nowOver = isOverDismiss()
                    if (nowOver != overDismiss) {
                        overDismiss = nowOver
                        dismissMark.scaleX = if (overDismiss) 1.25f else 1f
                        dismissMark.scaleY = if (overDismiss) 1.25f else 1f
                    }
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                hideDismissView()
                if (dragging) {
                    if (event.actionMasked == MotionEvent.ACTION_UP && isOverDismiss()) {
                        closeBubble()
                    } else {
                        snapToEdge()
                    }
                } else if (event.actionMasked == MotionEvent.ACTION_UP &&
                    event.eventTime - downTime < 400
                ) {
                    // ট্যাপ (ড্র্যাগ নয়): ভাসমান উইন্ডো টগল — পুরো অ্যাপ ওপরে ভাসে।
                    togglePanel()
                }
                dragging = false
                overDismiss = false
                return true
            }
        }
        return false
    }

    private fun updateDotLayout() {
        try {
            windowManager.updateViewLayout(dotView, dotParams)
        } catch (_: Exception) {
        }
    }

    /** ছেড়ে দিলে কাছের কিনারায় স্ন্যাপ — মাঝখানে ঝুলে থাকে না। */
    private fun snapToEdge() {
        val centerX = dotParams.x + dotSizePx / 2
        val targetX = if (centerX < screenW / 2) 0 else screenW - dotSizePx
        val startX = dotParams.x
        if (startX == targetX) {
            saveDotPosition()
            return
        }
        snapAnimator?.cancel()
        val anim = ValueAnimator.ofInt(startX, targetX).apply {
            duration = 180
            addUpdateListener {
                dotParams.x = it.animatedValue as Int
                updateDotLayout()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    // উইন্ডো খোলা থাকতে ডট টেনে সরালে "বাড়ি"ও সরে যাবে —
                    // লুকালে ডট নতুন জায়গায় ফিরবে।
                    if (dotParked) {
                        dotHomeX = dotParams.x
                        dotHomeY = dotParams.y
                    }
                    saveDotPosition()
                }
            })
        }
        snapAnimator = anim
        anim.start()
    }

    // ── বন্ধ-চিহ্ন (শুধু ড্র্যাগের সময়) ───────────────────────────────

    private fun setupDismissView() {
        val frame = FrameLayout(applicationContext)
        val mark = TextView(applicationContext).apply {
            text = "✕"
            textSize = 26f
            gravity = Gravity.CENTER
            setTextColor(0xFFFFFFFF.toInt())
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xFFDC4C4C.toInt())
                setSize(dp(56), dp(56))
            }
            layoutParams = FrameLayout.LayoutParams(dp(56), dp(56), Gravity.CENTER)
        }
        dismissMark = mark
        frame.addView(mark)
        frame.visibility = View.GONE
        dismissView = frame
        dismissParams = WindowManager.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(120),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.BOTTOM }
        windowManager.addView(frame, dismissParams)
        dismissAdded = true
    }

    private fun showDismissView() {
        try {
            dismissView.visibility = View.VISIBLE
        } catch (_: Exception) {
        }
    }

    private fun hideDismissView() {
        try {
            dismissView.visibility = View.GONE
        } catch (_: Exception) {
        }
    }

    private fun isOverDismiss(): Boolean {
        val cx = dotParams.x + dotSizePx / 2
        val cy = dotParams.y + dotSizePx / 2
        val tx = screenW / 2
        val ty = screenH - dp(70)
        return hypot((cx - tx).toDouble(), (cy - ty).toDouble()) < dp(90)
    }

    // ── প্যানেল (FlutterView) ──────────────────────────────────────────

    private fun togglePanel() {
        if (panelVisible) hidePanel() else showPanel()
    }

    private fun showPanel() {
        val view = flutterView ?: return
        // Messenger-এর মতো ভাসমান উইন্ডো: চারপাশে স্পষ্ট ফাঁকা — উপরে
        // ১১০dp, পাশে ৩২dp, নিচে ১১০dp। প্রায় পুরো স্ক্রিন নয়।
        val panelW = screenW - dp(64)
        val panelH = screenH - dp(220)
        panelParams = WindowManager.LayoutParams(
            panelW, panelH,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // ফোকাসেবল (কিবোর্ড আসবে) + বাইরের টাচ নিচের অ্যাপে যাবে।
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(32)
            y = dp(110)
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
        try {
            if (!panelAdded) {
                windowManager.addView(view, panelParams)
                panelAdded = true
            } else {
                windowManager.updateViewLayout(view, panelParams)
            }
            // উইন্ডো দেখানোর পর ফোকাস নেওয়া — কিবোর্ড/টাচ যাতে
            // ভেতরের FlutterView-এ পৌঁছায়।
            try {
                view.requestFocus()
            } catch (_: Exception) {
            }
            panelVisible = true
            // ডটটা উইন্ডোর উপরে বসবে (ডানদিকের কোণার ঠিক উপরে) — গায়ে
            // লেগে থাকবে না, যেকোনো সময় ট্যাপ করে লুকানো যাবে।
            parkDotAboveWindow()
        } catch (_: Exception) {
            panelVisible = false
        }
    }

    /** ডটকে উইন্ডোর উপরে বসায় (ডানদিকের কোণার ঠিক উপরে)। */
    private fun parkDotAboveWindow() {
        try {
            if (!dotParked) {
                dotHomeX = dotParams.x
                dotHomeY = dotParams.y
                dotParked = true
            }
            val params = panelParams ?: return
            dotParams.x = params.x + params.width - dotSizePx
            dotParams.y = params.y - dotSizePx - dp(8)
            bringDotToFront()
        } catch (_: Exception) {
        }
    }

    /** ডটকে আগের জায়গায় ফিরিয়ে দেয় (উইন্ডো লুকালে)। */
    private fun unparkDot() {
        try {
            if (!dotParked) return
            dotParked = false
            if (dotHomeX >= 0 && dotHomeY >= 0) {
                dotParams.x = dotHomeX
                dotParams.y = dotHomeY
                updateDotLayout()
                saveDotPosition()
            }
        } catch (_: Exception) {
        }
    }

    /** ডটকে সবচেয়ে সামনে আনে — উইন্ডো খুললেও ডট ট্যাপ করা যায়। */
    private fun bringDotToFront() {
        try {
            if (dotAdded) {
                windowManager.removeView(dotView)
                windowManager.addView(dotView, dotParams)
            }
        } catch (_: Exception) {
        }
    }

    private fun hidePanel() {
        unparkDot()
        if (!panelAdded) {
            panelVisible = false
            return
        }
        try {
            windowManager.removeView(flutterView)
        } catch (_: Exception) {
        }
        panelAdded = false
        panelVisible = false
    }

    private fun openApp() {
        hidePanel()
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    /** বাবল বন্ধ — X-এ ছাড়া, প্যানেলের ✕, বা Settings টগল — সব এখানেই আসে। */
    private fun closeBubble() {
        BubbleControl.stopBubble(applicationContext)
    }

    // ── সাহায্যকারী ────────────────────────────────────────────────────

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

    private fun loadDotPosition(): Pair<Int, Int> {
        val prefs = applicationContext.getSharedPreferences(
            BubbleControl.PREFS, Context.MODE_PRIVATE,
        )
        val x = prefs.getInt("dot_x", -1)
        val y = prefs.getInt("dot_y", -1)
        if (x < 0 || y < 0) {
            return (screenW - dotSizePx - dp(8)) to (screenH / 2 - dotSizePx / 2)
        }
        return x.coerceIn(0, max(0, screenW - dotSizePx)) to
            y.coerceIn(0, max(0, screenH - dotSizePx))
    }

    private fun saveDotPosition() {
        try {
            applicationContext.getSharedPreferences(BubbleControl.PREFS, Context.MODE_PRIVATE)
                .edit()
                .putInt("dot_x", dotParams.x)
                .putInt("dot_y", dotParams.y)
                .apply()
        } catch (_: Exception) {
        }
    }
}
