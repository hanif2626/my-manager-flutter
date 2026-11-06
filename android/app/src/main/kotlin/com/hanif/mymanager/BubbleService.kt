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
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Messenger-এর চ্যাট হেডের মতো ভাসমান বাবল — নিজের ফোরগ্রাউন্ড সার্ভিস।
 *
 * তিনটি আলাদা WindowManager ভিউ, তিনটি আলাদা কাজ — এটাই আগের ব্যর্থতার
 * মূল শিক্ষা। আগের প্লাগইন একটাই Flutter ভিউকে গোল → প্যানেল রিসাইজ
 * করত, আর Flutter-এর ভেতরে ড্র্যাগ করত; তাতেই ট্যাপ-বনাম-ড্র্যাগ দ্বন্দ্ব,
 * রিসাইজ-গ্লিচ আর Vivo-তে আটকে যাওয়া। এখানে:
 * - ডট (dotView): নেটিভ Android ভিউ। ড্র্যাগ, ট্যাপ, কিনারায় স্ন্যাপ —
 *   সব নেটিভে। Flutter-এর সঙ্গে এর কোনো সম্পর্ক নেই, তাই আটকায় না।
 * - প্যানেল (panelView): আলাদা FlutterView, নিজের FlutterEngine-এ
 *   `bubbleMain()` চালায়। ডটে ট্যাপ করলে দেখায়/লুকায়; ডট তখনো
 *   স্ক্রিনে থাকে, তাই আবার ট্যাপ করলেই প্যানেল লুকিয়ে যায়। পুরো অ্যাপ
 *   খোলে না — প্যানেলটাই অন্য অ্যাপের ওপরে ভাসে।
 * - বন্ধ-চিহ্ন (dismissView): শুধু ড্র্যাগ করার সময় নিচের মাঝখানে
 *   দেখা যায়। ডটটা তার ওপরে ছাড়লেই বাবল বন্ধ (enabled=false লিখে
 *   সার্ভিস থামে)।
 *
 * কিবোর্ড: ডট FLAG_NOT_FOCUSABLE (নিচের অ্যাপের ফোকাস চুরি করে না),
 * প্যানেল FLAG_NOT_TOUCH_MODAL + ফোকাসেবল (TextField-এ কিবোর্ড আসে,
 * বাইরে ট্যাপ করলে নিচের অ্যাপও টাচ পায়)।
 *
 * ডাটা: প্যানেলের engine আলাদা isolate — মূল অ্যাপের মেমরি/DB হ্যান্ডল
 * এখানে নেই। প্যানেল নিজে SQLite ফাইল খুলে একটাই ছোট insert/update করে,
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
        val view = FlutterView(applicationContext)
        view.attachToFlutterEngine(eng)
        flutterView = view
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
                        // সেভের খবর: মূল অ্যাপ DataSync-এর পোলে নিজেই ধরে
                        // ফেলে, তাই এখানে কিছু করার নেই — শুধু স্বীকার করা।
                        "noteSaved" -> result.success(true)
                        else -> result.notImplemented()
                    }
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
                    // ট্যাপ (ড্র্যাগ নয়): প্যানেল টগল — পুরো অ্যাপ খোলে না।
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
        val panelW = min(screenW - dp(32), dp(340))
        val panelH = min((screenH * 0.62).toInt(), dp(480))
        // ডটের পাশে, ডটের কাছাকাছি — ডানদিকে জায়গা থাকলে ডানে, নইলে বামে।
        val dotCenterX = dotParams.x + dotSizePx / 2
        var px = if (dotCenterX < screenW / 2) {
            dotParams.x + dotSizePx + dp(8)
        } else {
            dotParams.x - panelW - dp(8)
        }
        px = px.coerceIn(dp(8), max(dp(8), screenW - panelW - dp(8)))
        var py = dotParams.y - dp(24)
        py = py.coerceIn(dp(32), max(dp(32), screenH - panelH - dp(16)))
        panelParams = WindowManager.LayoutParams(
            panelW, panelH,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // ফোকাসেবল (কিবোর্ড আসবে) + বাইরের টাচ নিচের অ্যাপে যাবে।
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = px
            y = py
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }
        try {
            if (!panelAdded) {
                windowManager.addView(view, panelParams)
                panelAdded = true
            } else {
                windowManager.updateViewLayout(view, panelParams)
            }
            panelVisible = true
            // প্যানেল খুললেই Dart-কে বলো — তাজা প্রজেক্ট/আইডিয়া পড়ে নেবে।
            try {
                panelChannel?.invokeMethod("onPanelShown", null)
            } catch (_: Exception) {
            }
        } catch (_: Exception) {
            panelVisible = false
        }
    }

    private fun hidePanel() {
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
