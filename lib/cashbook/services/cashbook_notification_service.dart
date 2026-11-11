import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import '../db/cashbook_db.dart';
import 'cashbook_service.dart';
import '../../reminder/services/reminder_service.dart';

/// "রাত ৮টা থেকে শুরু করে প্রতি ৩০ মিনিটে মনে করিয়ে দাও, যতক্ষণ না আজ
/// অন্তত একটা এন্ট্রি হয়" — implemented as a fixed chain of *exact*
/// alarms (8:00, 8:30, ... 11:30pm), not a single schedule plus a
/// periodic background poll. Exact alarms (AndroidScheduleMode.
/// exactAllowWhileIdle, backed by USE_EXACT_ALARM in the manifest) are
/// far more likely to actually fire on time on battery-aggressive OEMs
/// (Xiaomi/Vivo/Oppo/Realme) than WorkManager's ~30-min periodic jobs,
/// which Android is free to delay by hours under Doze.
///
/// [refresh] is idempotent and cheap to call often: cancels every slot,
/// then — only if today has no entry yet — re-arms every slot that
/// hasn't already passed. Call it whenever the day's entry state could
/// have changed: app open/resume, Cashbook screen load, and right after
/// saving/deleting an entry — that last one is what makes the reminder
/// actually stop the moment a real entry is logged, not just at the
/// next 30-min poll.
class CashbookNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _channelId = 'cashbook_reminder_channel';

  // সেটিংসে ব্যবহারকারীর দেওয়া সময় থেকে শুরু করে, প্রতি ৩০ মিনিটে, রাত ১১:৩০
  // পর্যন্ত (বা শুরুর সময় তার পরে হলে অন্তত একটা স্লট) — প্রতিটা স্লট নিজের
  // নোটিফিকেশন আইডি নিয়ে আলাদাভাবে শিডিউল/বাতিল হয়।
  static List<(int, int)> get _slots {
    final startH = CashbookService.reminderHour.clamp(0, 23);
    final startM = CashbookService.reminderMinute >= 30 ? 30 : 0;
    var totalMin = startH * 60 + startM;
    const lastMin = 23 * 60 + 30; // রাত ১১:৩০
    final slots = <(int, int)>[];
    while (totalMin <= lastMin && slots.length < 8) {
      slots.add((totalMin ~/ 60, totalMin % 60));
      totalMin += 30;
    }
    if (slots.isEmpty) slots.add((23, 30)); // দিন প্রায় শেষ হলেও একটা স্লট থাকুক
    return slots;
  }

  static int _idFor(int hour, int minute) => 7700 + hour * 2 + (minute == 30 ? 1 : 0);

  static Future<void> _init() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    // Without this, tz.local silently defaults to UTC, and every
    // zonedSchedule below fires 6 hours off in Bangladesh (a "8pm"
    // schedule actually lands at 2am local time) — this was the exact
    // bug behind the 8pm reminder never showing up in the first place.
    try {
      // flutter_timezone's return type has changed across versions —
      // older ones give a plain String, newer ones a TimezoneInfo object
      // with an .identifier field. Handling both dynamically avoids
      // guessing wrong and failing the build over a package version
      // detail that doesn't actually matter for what we need here.
      final dynamic tzResult = await FlutterTimezone.getLocalTimezone();
      final String tzName = tzResult is String ? tzResult : (tzResult.identifier as String);
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {
      // Fall back to UTC rather than crashing — reminders would fire at
      // the wrong time instead of not existing at all.
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Reminder callbacks must be re-registered here: the plugin instance is
    // shared app-wide and the last initialize() call wins.
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: ReminderService.onForeground,
      onDidReceiveBackgroundNotificationResponse: reminderBackgroundHandler,
    );
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
    try {
      // Android 12+ gates exact alarms behind this separate permission.
      // USE_EXACT_ALARM in the manifest auto-grants it for most installs,
      // but requesting explicitly is harmless and covers edge cases.
      await androidImpl?.requestExactAlarmsPermission();
    } catch (_) {
      // Older flutter_local_notifications versions or OEMs without this
      // API — exact alarms may just silently fall back to inexact.
    }
    _initialized = true;
  }

  // পুরো দিনের যেকোনো সম্ভাব্য স্লট (0:00–23:30) বাতিল করে — যাতে
  // ব্যবহারকারী রিমাইন্ডারের সময় বদলালে আগের সময়ের বসানো নোটিফিকেশনও
  // ঠিকভাবে মুছে যায়, শুধু আজকের স্লট-তালিকার সাথে মিলে গেলে নয়।
  static Future<void> _cancelAllSlots() async {
    for (var h = 0; h < 24; h++) {
      await _plugin.cancel(_idFor(h, 0));
      await _plugin.cancel(_idFor(h, 30));
    }
  }

  static Future<void> refresh() async {
    await _init();
    await _cancelAllSlots();

    if (!CashbookService.reminderEnabled) return; // ব্যবহারকারী বন্ধ রেখেছে

    final hasEntry = await CashbookDB.hasEntryToday();
    if (hasEntry) return; // today's already logged — nothing to nag about

    final now = DateTime.now();
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      'ক্যাশবুক রিমাইন্ডার',
      channelDescription: 'আজকের জমা-খরচ এন্ট্রি না দেওয়া থাকলে সন্ধ্যা থেকে রাত পর্যন্ত মনে করিয়ে দেয়',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    for (final (hour, minute) in _slots) {
      var scheduled = DateTime(now.year, now.month, now.day, hour, minute);
      if (scheduled.isBefore(now)) continue; // that slot's already passed today
      await _plugin.zonedSchedule(
        _idFor(hour, minute),
        '🧾 আজকের হিসাব এখনও লেখা হয়নি',
        'ক্যাশবুকে আজকের জমা/খরচ যোগ করো — অন্তত একটা এন্ট্রি দিলেই আর মনে করাবে না',
        tz.TZDateTime.from(scheduled, tz.local),
        const NotificationDetails(android: androidDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  static Future<void> cancel() async {
    await _cancelAllSlots();
  }

  /// Called every ~30 minutes by a background WorkManager task (see
  /// main.dart) as a redundant safety net — e.g. if the app was never
  /// opened all day so the exact alarms above never got armed in the
  /// first place. Just re-runs the same idempotent [refresh] logic;
  /// WorkManager's own timing looseness no longer matters for whether
  /// the reminder fires on time, only for whether it gets armed at all.
  static Future<void> backgroundCheck() async {
    if (!CashbookService.reminderEnabled) return;
    final now = DateTime.now();
    final startMin = CashbookService.reminderHour * 60 +
        (CashbookService.reminderMinute >= 30 ? 30 : 0);
    if (now.hour * 60 + now.minute < startMin) return;
    await refresh();
  }

  /// খরচ-প্রহরীর বড় লাল সতর্কতা (SpendingGuard থেকে)। সর্বোচ্চ গুরুত্বের চ্যানেলে, বড় লেখাসহ।
  static Future<void> showGuardNudge({required String title, required String body, required bool danger}) async {
    await _init();
    final details = AndroidNotificationDetails(
      'spending_guard_channel',
      'খরচ সতর্কতা',
      channelDescription: 'আবশ্যিক খরচের টাকা কমে গেলে লাল সতর্কতা',
      importance: Importance.max,
      priority: Priority.max,
      icon: '@mipmap/ic_launcher',
      color: danger ? const Color(0xFFDC2626) : const Color(0xFFF59E0B),
      colorized: true,
      category: AndroidNotificationCategory.reminder,
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
    );
    await _plugin.show(7800, title, body.split('\n').first, NotificationDetails(android: details));
  }

  // ───────────── স্থায়ী নোটিফিকেশন-বার সতর্কতা (আইডি ৭৮২০) ─────────────
  static const _guardOngoingId = 7820;

  /// ব্যালেন্স আবশ্যিক খরচের নিচে/কাছাকাছি থাকলে নোটিফিকেশন বারে
  /// লেগে-থাকা (ongoing) সতর্কতা — অবস্থা না বদলানো পর্যন্ত থাকবে,
  /// যাতে যেকোনো সময় ফোনের উপর দিকে দেখে আগাম পরিকল্পনা করা যায়।
  /// danger হলে লাল, কাছাকাছি হলে হলুদ অ্যাকসেন্ট।
  static Future<void> showGuardOngoing({required String title, required String body, required bool danger}) async {
    await _init();
    final details = AndroidNotificationDetails(
      'spending_guard_channel',
      'খরচ সতর্কতা',
      channelDescription: 'ব্যালেন্স আবশ্যিক খরচের তুলনায় কমে গেলে নোটিফিকেশন বারে স্থায়ী সতর্কতা',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: danger ? const Color(0xFFDC2626) : const Color(0xFFF59E0B),
      colorized: true,
      category: AndroidNotificationCategory.reminder,
      ongoing: true,
      autoCancel: false,
      styleInformation: BigTextStyleInformation(body, contentTitle: title),
    );
    await _plugin.show(_guardOngoingId, title, body.split('\n').first, NotificationDetails(android: details));
  }

  static Future<void> cancelGuardOngoing() async {
    await _init();
    await _plugin.cancel(_guardOngoingId);
  }

  // ───────────── খরচ-প্রহরীর ৩ বেলার সতর্কতা (আইডি ৭৮১০–৭৮১৯) ─────────────
  static const _guardSlotBase = 7810;
  static const _guardSlotCount = 10;

  static Future<void> cancelGuardSlots() async {
    await _init();
    for (var i = 0; i < _guardSlotCount; i++) {
      await _plugin.cancel(_guardSlotBase + i);
    }
  }

  /// আগের বসানো সব ৩-বেলা নোটিফিকেশন বাতিল করে [msgs]-এর প্রতিটা সঠিক সময়ে (exact alarm) বসায়।
  /// প্রতিবার নতুন করে বসানো হয় বলে কিস্তি মেটানোর পরের ডাটাই সবসময় দেখায়।
  static Future<void> scheduleGuardSlots(
      List<({DateTime when, String title, String body, bool danger})> msgs) async {
    await cancelGuardSlots();
    var id = _guardSlotBase;
    for (final m in msgs.take(_guardSlotCount)) {
      final details = AndroidNotificationDetails(
        'spending_guard_channel',
        'খরচ সতর্কতা',
        channelDescription: 'কিস্তি/আবশ্যিক খরচ বাকি থাকলে প্রতিদিন ৩ বেলা সতর্কতা',
        importance: Importance.max,
        priority: Priority.max,
        icon: '@mipmap/ic_launcher',
        color: m.danger ? const Color(0xFFDC2626) : const Color(0xFFF59E0B),
        colorized: true,
        category: AndroidNotificationCategory.reminder,
        styleInformation: BigTextStyleInformation(m.body, contentTitle: m.title),
      );
      await _plugin.zonedSchedule(
        id++,
        m.title,
        m.body.split('\n').first,
        tz.TZDateTime.from(m.when, tz.local),
        NotificationDetails(android: details),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  /// MIUI/FunTouch/ColorOS-style battery managers on Xiaomi, Vivo, Oppo
  /// and some Samsung phones aggressively kill background work — no
  /// amount of app-side code fixes that, only the person granting an
  /// exemption does. Asks once, only if not already granted; safe to
  /// call repeatedly since it no-ops once granted or once permanently
  /// denied.
  static Future<void> requestBatteryExemptionIfNeeded() async {
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {
      // Not available on this platform/OEM — never block the app for it.
    }
  }
}
