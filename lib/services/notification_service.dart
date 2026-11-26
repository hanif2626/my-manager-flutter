import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter/material.dart';
import '../reminder/services/reminder_service.dart';
import '../today/today_service.dart';
import 'settings_service.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _channelId = 'my_manager_channel';
  static const _digestId = 9999; // fixed ID for daily digest

  static Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    // Without this, tz.local silently defaults to UTC and every
    // zonedSchedule below fires 6 hours off in Bangladesh (e.g. an 8pm
    // schedule actually lands at 2am local time).
    try {
      final dynamic tzResult = await FlutterTimezone.getLocalTimezone();
      final String tzName = tzResult is String ? tzResult : (tzResult.identifier as String);
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {
      // Fall back to UTC rather than crashing — reminders will just
      // fire at the wrong time instead of not existing at all.
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);

    await _plugin.initialize(
      settings,
      // Same callbacks as ReminderService — the plugin is a singleton and the
      // last initialize() call wins, so every caller must register these or
      // the reminder Done / Not yet buttons stop working.
      onDidReceiveNotificationResponse: (details) {
        debugPrint('Notification tapped: ${details.payload}');
        ReminderService.onForeground(details);
      },
      onDidReceiveBackgroundNotificationResponse: reminderBackgroundHandler,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialized = true;
    debugPrint('NotificationService initialized');
  }

  static Future<void> scheduleNotification(
      int id, String title, String body, DateTime scheduledTime) async {
    await init();

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      'My Manager Reminders',
      channelDescription: 'Project reminder notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      enableVibration: true,
      playSound: true,
    );

    const details = NotificationDetails(android: androidDetails);
    final tzTime = tz.TZDateTime.from(scheduledTime, tz.local);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzTime,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: id > 1000 ? 'idea_${id - 1000}' : 'project_$id',
    );

    debugPrint('Scheduled notification #$id at $scheduledTime');
  }

  static Future<void> cancelNotification(int id) async {
    await _plugin.cancel(id);
  }

  static Future<void> showInstant(String title, String body) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      'My Manager Reminders',
      channelDescription: 'Project reminder notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    await _plugin.show(0, title, body,
        const NotificationDetails(android: androidDetails));
  }

  /// সকালের "আজকের ম্যানেজার" নোটিফিকেশন: রিমাইন্ডার, চাকরির ডেডলাইন, বিল,
  /// জন্মদিন, বাজেট, প্রজেক্ট — সব মডিউল মিলিয়ে (TodayService)। সময় ও চালু/বন্ধ
  /// সেটিংসের Daily digest থেকে আসে (ডিফল্ট সকাল ৮টা)।
  ///
  /// বিষয়বস্তু শিডিউল করার মুহূর্তে হিসাব করা হয় (ফায়ারের দিনের হিসাবে), তাই এটা
  /// একবারের নোটিফিকেশন — অ্যাপ খুললে, রিজিউম হলে আর প্রতি ৬ ঘণ্টার ব্যাকগ্রাউন্ড
  /// টাস্কে নতুন করে বসে। জরুরি/আসন্ন কিছু না থাকলে কোনো নোটিফিকেশন যায় না।
  static Future<void> scheduleDailyDigest({int? hour, int? minute}) async {
    await init();
    await _plugin.cancel(_digestId);

    if (!SettingsService.getBool('digest_enabled', defaultValue: true)) return;
    final h = hour ?? SettingsService.getInt('digest_hour', defaultValue: 8);
    final m = minute ?? SettingsService.getInt('digest_minute', defaultValue: 0);

    final now = DateTime.now();
    var fireAt = DateTime(now.year, now.month, now.day, h, m);
    if (!fireAt.isAfter(now)) fireAt = fireAt.add(const Duration(days: 1));

    final summary = await TodayService.build(asOf: fireAt, includeBackupHints: false);
    if (!summary.worthNotifying) return;

    final androidDetails = AndroidNotificationDetails(
      'daily_digest_channel',
      'Daily Digest',
      channelDescription: 'প্রতিদিনের কাজের সারসংক্ষেপ',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
      styleInformation: BigTextStyleInformation(
        summary.notificationBody(),
        contentTitle: '${TodaySummary.greeting(h)} আজকের ম্যানেজার',
        summaryText: summary.notificationShort,
      ),
    );

    await _plugin.zonedSchedule(
      _digestId,
      '${TodaySummary.greeting(h)} আজকের ম্যানেজার',
      summary.notificationShort,
      tz.TZDateTime.from(fireAt, tz.local),
      NotificationDetails(android: androidDetails),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'today_digest',
    );

    debugPrint('Morning digest scheduled for $fireAt → ${summary.notificationShort}');
  }

  // ───────────── Job Radar-এর রাতের রিপোর্ট ─────────────
  // আইডি: ৯১০০ = সরাসরি দেখানো রিপোর্ট; ৯১০১–৯১০৩ = নির্ধারিত সময়ের (অ্যালার্ম) রিপোর্ট।
  static const _radarShowId = 9100;
  static const _radarAlarmBase = 9101;
  static const _radarAlarmCount = 3;

  static AndroidNotificationDetails _radarDetails(String title, String body, String big,
          {bool onlyAlertOnce = false}) =>
      AndroidNotificationDetails(
        'radar_daily_channel_v2',
        'Job Radar (প্রতিদিন)',
        channelDescription: 'প্রতিদিন নির্দিষ্ট সময়ে উপযুক্ত সরকারি চাকরির সার্কুলার, পদসংখ্যা ও শেষ তারিখ',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        onlyAlertOnce: onlyAlertOnce,
        styleInformation: BigTextStyleInformation(big, contentTitle: title, summaryText: body),
      );

  /// রাতের রিপোর্ট দেখায়। সময়মতো অ্যালার্মের নোটিফিকেশন আগেই এসে থাকলে সেটাই (একই আইডিতে, নিঃশব্দে)
  /// তাজা তথ্য দিয়ে হালনাগাদ করে — যাতে একই রাতে দুটো আলাদা নোটিফিকেশন না আসে।
  static Future<void> showRadarReport(String title, String body, String bigText) async {
    await init();
    var id = _radarShowId;
    var quiet = false;
    try {
      final active = await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.getActiveNotifications();
      for (final n in active ?? const <ActiveNotification>[]) {
        final nid = n.id ?? -1;
        if (nid >= _radarAlarmBase && nid < _radarAlarmBase + _radarAlarmCount) {
          id = nid;
          quiet = true;
          break;
        }
      }
    } catch (_) {}
    await _plugin.show(id, title, body,
        NotificationDetails(android: _radarDetails(title, body, bigText, onlyAlertOnce: quiet)),
        payload: 'job_radar');
  }

  // ───────────── নোটিফিকেশন/অ্যালার্ম ডায়াগনস্টিক (রাডার সেটিংসে "অবস্থা দেখো") ─────────────

  /// ফোন আসলেই অ্যাপকে নোটিফিকেশন/সঠিক-সময়ের অ্যালার্ম দিচ্ছে কি না এবং কী কী অ্যালার্ম বসে আছে — পাঠযোগ্য লাইনে।
  static Future<List<String>> diagnostics() async {
    await init();
    final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final out = <String>[];
    try {
      final on = await a?.areNotificationsEnabled();
      out.add(on == true ? '✅ নোটিফিকেশন চালু আছে' : '❌ নোটিফিকেশন বন্ধ — ফোনের সেটিংসে অ্যাপের নোটিফিকেশন চালু করো');
    } catch (_) {}
    try {
      final ex = await a?.canScheduleExactNotifications();
      out.add(ex == true
          ? '✅ সঠিক-সময়ের অ্যালার্মের অনুমতি আছে'
          : '❌ সঠিক-সময়ের অ্যালার্মের অনুমতি নেই — নোটিফিকেশন অনেক দেরিতে আসবে বা আসবে না');
    } catch (_) {}
    try {
      final pend = await _plugin.pendingNotificationRequests();
      int inRange(int lo, int hi) => pend.where((p) => p.id >= lo && p.id < hi).length;
      out.add('🕒 বসে থাকা অ্যালার্ম: রাডার রিপোর্ট ${inRange(_radarAlarmBase, _radarAlarmBase + _radarAlarmCount)}টি · '
          'শেষ তারিখ ${inRange(_radarDeadlineBase, _radarDeadlineBase + _radarDeadlineMax)}টি · '
          'রিমাইন্ডার ${pend.where((p) => p.id >= 100000000).length}টি · মোট ${pend.length}টি');
    } catch (_) {}
    return out;
  }

  /// সঠিক-সময়ের অ্যালার্মের অনুমতি চায় (দরকার হলে ফোনের সেটিংস খোলে)।
  static Future<void> requestExactAlarmPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestExactAlarmsPermission();
  }

  /// [seconds] সেকেন্ড পরে একটা পরীক্ষা নোটিফিকেশন (অ্যালার্ম দিয়ে) — অ্যাপ বন্ধ করে অপেক্ষা করলে বোঝা যায়
  /// ফোন ব্যাকগ্রাউন্ডে অ্যালার্ম ঠিকমতো পৌঁছে দিচ্ছে কি না।
  static Future<void> scheduleTestAlarm({int seconds = 60}) async {
    await init();
    final at = tz.TZDateTime.from(DateTime.now().add(Duration(seconds: seconds)), tz.local);
    const d = AndroidNotificationDetails(
      'radar_new_channel',
      'Job Radar (নতুন সার্কুলার)',
      channelDescription: 'যোগ্য নতুন সরকারি চাকরির সার্কুলার এলেই সাথে সাথে',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const title = '🔔 পরীক্ষা অ্যালার্ম সফল';
    const body = 'অ্যাপ বন্ধ থাকা অবস্থায়ও অ্যালার্ম ঠিকমতো এসেছে — শেষ তারিখ ও রিপোর্টের নোটিফিকেশনও আসবে।';
    try {
      await _plugin.zonedSchedule(9199, title, body, at, const NotificationDetails(android: d),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: 'job_radar');
    } catch (_) {
      await _plugin.zonedSchedule(9199, title, body, at, const NotificationDetails(android: d),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: 'job_radar');
    }
  }

  /// নতুন সার্কুলার/বাড়ানো শেষ তারিখ — সাথে সাথে জানানো (একই আইডি: একাধিক হলে একটাই নোটিফিকেশনে জমে)।
  static Future<void> showRadarNew(String title, String body, String bigText,
      {String? focusUrl}) async {
    await init();
    final d = AndroidNotificationDetails(
      'radar_new_channel',
      'Job Radar (নতুন সার্কুলার)',
      channelDescription: 'যোগ্য নতুন সরকারি চাকরির সার্কুলার এলেই সাথে সাথে',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      styleInformation: BigTextStyleInformation(bigText, contentTitle: title, summaryText: body),
    );
    await _plugin.show(9110, title, body, NotificationDetails(android: d),
        payload: (focusUrl == null || focusUrl.isEmpty)
            ? 'job_radar'
            : 'job_item|${Uri.encodeComponent(focusUrl)}');
  }

  /// প্রবেশপত্র নজরদারি: সাইটে নতুন প্রবেশপত্রের লিংক/নোটিশ পাওয়া গেলে (আইডি ৯৪০০–৯৪৮৯, সার্কুলার ধরে)।
  static Future<void> showAdmitFound(int circularId, String title, String body, String bigText) async {
    await init();
    final d = AndroidNotificationDetails(
      'admit_card_channel',
      'প্রবেশপত্র নজরদারি',
      channelDescription: 'আবেদন করা সার্কুলারের প্রবেশপত্র প্রকাশ হলে',
      importance: Importance.max,
      priority: Priority.max,
      icon: '@mipmap/ic_launcher',
      category: AndroidNotificationCategory.reminder,
      styleInformation: BigTextStyleInformation(bigText, contentTitle: title, summaryText: body),
    );
    await _plugin.show(9400 + (circularId % 90), title, body, NotificationDetails(android: d), payload: 'job_admit|$circularId');
  }

  // ── শেষ তারিখ ঘনিয়ে এলে (আইডি ৯২০০–৯৩১৯) ──
  static const _radarDeadlineBase = 9200;
  static const _radarDeadlineMax = 120;

  static Future<void> cancelRadarDeadlineAlarms() async {
    await init();
    try {
      final pending = await _plugin.pendingNotificationRequests();
      for (final p in pending) {
        if (p.id >= _radarDeadlineBase && p.id < _radarDeadlineBase + _radarDeadlineMax) {
          await _plugin.cancel(p.id);
        }
      }
    } catch (_) {}
  }

  /// সার্কুলারের আবেদনের শেষ তারিখের আগের সতর্কতা ফোনের অ্যালার্মে আগেই বসায় — ইন্টারনেট বা
  /// ব্যাকগ্রাউন্ড টাস্ক না চললেও ঠিক সময়ে আসে। যতবার খুশি ডাকা যায় (আগেরগুলো বাতিল করে নতুন বসায়)।
  static Future<void> scheduleRadarDeadlineAlarms(
      List<({DateTime when, String title, String body, String big, String url})> msgs) async {
    await cancelRadarDeadlineAlarms();
    var id = _radarDeadlineBase;
    for (final m in msgs.take(_radarDeadlineMax)) {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'radar_deadline_channel',
          'Job Radar (শেষ তারিখ)',
          channelDescription: 'সরকারি চাকরির আবেদনের শেষ তারিখ ঘনিয়ে এলে সতর্কতা',
          importance: Importance.max,
          priority: Priority.max,
          icon: '@mipmap/ic_launcher',
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(m.big, contentTitle: m.title, summaryText: m.body),
        ),
      );
      final at = tz.TZDateTime.from(m.when, tz.local);
      final payload = m.url.isEmpty
          ? 'job_radar'
          : 'job_item|${Uri.encodeComponent(m.url)}';
      try {
        await _plugin.zonedSchedule(id, m.title, m.body, at, details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: payload);
      } catch (_) {
        try {
          await _plugin.zonedSchedule(id, m.title, m.body, at, details,
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
              payload: payload);
        } catch (_) {}
      }
      id++;
    }
  }

  static Future<void> cancelRadarAlarms() async {
    await init();
    for (var i = 0; i < _radarAlarmCount; i++) {
      await _plugin.cancel(_radarAlarmBase + i);
    }
  }

  /// আগের নির্ধারিত রিপোর্ট বাতিল করে [msgs]-এর প্রতিটা সঠিক সময়ে বসায়। যতবার খুশি ডাকা যায়।
  static Future<void> scheduleRadarAlarms(
      List<({DateTime when, String title, String body, String big})> msgs) async {
    await cancelRadarAlarms();
    var id = _radarAlarmBase;
    for (final m in msgs.take(_radarAlarmCount)) {
      final details = NotificationDetails(android: _radarDetails(m.title, m.body, m.big));
      final at = tz.TZDateTime.from(m.when, tz.local);
      try {
        await _plugin.zonedSchedule(id, m.title, m.body, at, details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: 'job_radar');
      } catch (_) {
        // সঠিক-সময়ের অনুমতি না থাকলে কাছাকাছি সময়ে (inexact) — তবুও আসবে
        await _plugin.zonedSchedule(id, m.title, m.body, at, details,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: 'job_radar');
      }
      id++;
    }
  }

  static Future<void> cancelDailyDigest() async {
    await _plugin.cancel(_digestId);
  }

  static Future<List<PendingNotificationRequest>> getPending() async {
    return _plugin.pendingNotificationRequests();
  }
}
