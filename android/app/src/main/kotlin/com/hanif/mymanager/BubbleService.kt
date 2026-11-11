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
import kotlin.math.hypot
import kotlin.math.max

/**
 * Messenger-এর চ্যাট হেডের মতো ভাসমান বাবল — নিজের ফোরগ্রাউন্ড সার্ভিস।
 *
 * পথ B (২০২৬-১১-১১): প্যানেল আর এই সার্ভিসের overlay উইন্ডোতে
 * FlutterView হিসেবে চলে না — Service-উইন্ডোতে Activity-context,
 * lifecycle আর সঠিক attach/detach ক্রম না থাকায় ভেতরের বাটন/টাচ
 * অনিয়মিত হতো। এখন এই সার্ভিস শুধু দুটি নেটিভ overlay রাখে:
 * - ডট (dotView): নেটিভ Android ভিউ — ড্র্যাগ, ট্যাপ, কিনারায় স্ন্যাপ।
 *   ট্যাপ করলে BubbleActivity খোলে/বন্ধ হয় (প্যানেল = আসল Activity,
 *   নিজের engine-এ পুরো অ্যাপ)।
 * - বন্ধ-চিহ্ন (dismissView): শুধু ড্র্যাগ করার সময় নিচের মাঝখানে
 *   দেখা যায়। ডটটা তার ওপরে ছাড়লেই বাবল বন্ধ।
 *
 * প্যানেলের অবস্থা BubbleActivity নিজে intent দিয়ে জানায়
 * (OPENED/RESUMED/PAUSED/CLOSED) — সার্ভিস তাতেই টগল ঠিক করে আর
 * ডটকে প্যানেলের উপরে বসায়/আগের জায়গায় ফেরত নেয়।
 */
class BubbleService : Service() {

    companion object {
        const val ACTION_START = "com.hanif.mymanager.bubble.START"
        const val ACTION_STOP = "com.hanif.mymanager.bubble.STOP"
        const val ACTION_PANEL_OPENED = "com.hanif.mymanager.bubble.PANEL_OPENED"
        const val ACTION_PANEL_RESUMED = "com.hanif.mymanager.bubble.PANEL_RESUMED"
        const val ACTION_PANEL_PAUSED = "com.hanif.mymanager.bubble.PANEL_PAUSED"
        const val ACTION_PANEL_CLOSED = "com.hanif.mymanager.bubble.PANEL_CLOSED"

        @Volatile
        var isRunning: Boolean = false
            private set

        private const val NOTIF_ID = 1001
        private const val NOTIF_CHANNEL_ID = "my_manager_bubble"
    }

    private lateinit var windowManager: WindowManager

    private lateinit var dotView: FrameLayout
    private lateinit var dotParams: WindowManager.LayoutParams
    private lateinit var dismissView: FrameLayout
    private lateinit var dismissParams: WindowManager.LayoutParams
    private lateinit var dismissMark: TextView

    private var dotAdded = false
    private var dismissAdded = false

    // প্যানেল (BubbleActivity) আছে কিনা / সামনে দেখা যাচ্ছে কিনা।
    private var panelExists = false
    private var panelVisible = false

    // ডটের "বাড়ি" — প্যানেল খুললে ডট উপরে বসে, লুকালে এখানে ফেরে।
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
        setupDismissView()
        setupDotView()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PANEL_OPENED -> panelExists = true
            ACTION_PANEL_RESUMED -> {
                panelExists = true
                panelVisible = true
                parkDotAboveWindow()
            }
            ACTION_PANEL_PAUSED -> {
                panelVisible = false
                unparkDot()
            }
            ACTION_PANEL_CLOSED -> {
                panelExists = false
                panelVisible = false
                unparkDot()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        snapAnimator?.cancel()
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
                    // ট্যাপ (ড্র্যাগ নয়): প্যানেল (BubbleActivity) টগল।
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
                    // প্যানেল খোলা থাকতে ডট টেনে সরালে "বাড়ি"ও সরে যাবে —
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

    // ── প্যানেল (BubbleActivity) ───────────────────────────────────────

    private fun togglePanel() {
        if (panelVisible) closePanel() else openPanel()
    }

    /** প্যানেল খোলে বা লুকিয়ে থাকলে সামনে আনে। */
    private fun openPanel() {
        // overlay উইন্ডো (ডট) দৃশ্যমান থাকায় background থেকে Activity
        // চালুর ছাড়ের আওতায় পড়ে (Android 10+)।
        val intent = Intent(applicationContext, BubbleActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    /** প্যানেল বন্ধ করে — Activity নিজে finish() হয়। */
    private fun closePanel() {
        val intent = Intent(applicationContext, BubbleActivity::class.java).apply {
            action = BubbleActivity.ACTION_CLOSE
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    /** ডটকে প্যানেলের উপরে বসায় (ডানদিকের কোণার ঠিক উপরে)। */
    private fun parkDotAboveWindow() {
        try {
            if (!dotParked) {
                dotHomeX = dotParams.x
                dotHomeY = dotParams.y
                dotParked = true
            }
            // BubbleActivity-র জ্যামিতি: x=32dp, প্রস্থ = screenW−64dp, y=110dp।
            dotParams.x = dp(32) + (screenW - dp(64)) - dotSizePx
            dotParams.y = dp(110) - dotSizePx - dp(8)
            bringDotToFront()
        } catch (_: Exception) {
        }
    }

    /** ডটকে আগের জায়গায় ফিরিয়ে দেয় (প্যানেল লুকালে/বন্ধ হলে)। */
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

    /** ডটকে সবচেয়ে সামনে আনে — প্যানেল খুললেও ডট ট্যাপ করা যায়। */
    private fun bringDotToFront() {
        try {
            if (dotAdded) {
                windowManager.removeView(dotView)
                windowManager.addView(dotView, dotParams)
            }
        } catch (_: Exception) {
        }
    }

    /** বাবল বন্ধ — X-এ ছাড়া বা Settings টগল — সব এখানেই আসে। */
    private fun closeBubble() {
        if (panelExists) closePanel()
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
