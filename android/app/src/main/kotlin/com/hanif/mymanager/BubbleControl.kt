package com.hanif.mymanager

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.ContextCompat

/**
 * ভাসমান বাবলের একমাত্র নিয়ন্ত্রণ-কেন্দ্র (Messenger-এর চ্যাট হেডের মতো)।
 *
 * ডিজাইন — কেন এটা, আগের প্লাগইন নয়:
 * - বাবলটা সবসময় থাকতে হবে (বা ব্যবহারকারী যখন চায় তখন), শুধু নোটিফিকেশন
 *   এলে নয়। তাই Android 11-এর Bubbles API নয় — সেটা নোটিফিকেশন-নির্ভর
 *   কথোপকথনের জন্য। এখানে SYSTEM_ALERT_WINDOW ওভারলে + ফোরগ্রাউন্ড
 *   সার্ভিসই সঠিক রাস্তা, কিন্তু নিজের Kotlin কোডে — তৃতীয় পক্ষের
 *   overlay প্লাগইন আর নয় (আগেরটা অরক্ষিত, তার নেটিভ ড্র্যাগ Vivo-তে
 *   আটকে যেত, আর showOverlay()-এ enableDrag:true রেখে দেওয়ার মতো
 *   দ্বন্দ্ব ছিল)।
 * - চালু/বন্ধের সত্য একটাই জায়গায়: এই ফাইলের SharedPreferences
 *   ("bubble_prefs" / "enabled")। Dart-এর SettingsService-এর
 *   "bubble_enabled" শুধু তার আয়না — অ্যাপ খুললে main.dart দুটো
 *   মিলিয়ে নেয়। ড্র্যাগ-টু-X দিয়ে বন্ধ করলে সার্ভিস নিজে এখানে
 *   enabled=false লিখে দেয়, তাই পরের বার অ্যাপ খুললেও বাবল আর
 *   নিজে থেকে ফিরে আসে না; আবার চালু করতে হয় Settings থেকে।
 */
object BubbleControl {
    const val PREFS = "bubble_prefs"
    const val KEY_ENABLED = "enabled"
    const val CHANNEL = "com.hanif.mymanager/bubble"

    fun isOverlayGranted(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

    fun isBubbleEnabled(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)

    fun isBubbleRunning(): Boolean = BubbleService.isRunning

    /** "অন্য অ্যাপের ওপরে দেখাও" সেটিংস পাতা খোলে (এর কোনো রানটাইম ডায়ালগ নেই)। */
    fun openOverlaySettings(activity: Activity) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${activity.packageName}"),
        )
        activity.startActivity(intent)
    }

    /** বাবলের নিজের ইঞ্জিন (Service) থেকে সেটিংস পাতা খোলে — Activity নেই বলে NEW_TASK লাগে। */
    fun openOverlaySettingsFromService(ctx: Context) {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${ctx.packageName}"),
        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        ctx.startActivity(intent)
    }

    /** ফোরগ্রাউন্ড থেকে ডাকা হয় (Settings টগল / অ্যাপ চালু) — ব্যাকগ্রাউন্ড থেকে নয়। */
    fun startBubble(ctx: Context): Boolean {
        if (!isOverlayGranted(ctx)) return false
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, true).apply()
        val intent = Intent(ctx, BubbleService::class.java)
            .apply { action = BubbleService.ACTION_START }
        ContextCompat.startForegroundService(ctx, intent)
        return true
    }

    fun stopBubble(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, false).apply()
        ctx.stopService(Intent(ctx, BubbleService::class.java))
    }
}
