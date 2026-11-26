import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../db/reminder_db.dart';
import '../models/reminder.dart';

/// নোটিফিকেশনের Done / Not yet বাটন চাপলে অ্যাপ বন্ধ থাকলেও এই
/// ফাংশন আলাদা ব্যাকগ্রাউন্ড আইসোলেটে চলে।
@pragma('vm:entry-point')
Future<void> reminderBackgroundHandler(NotificationResponse response) async {
  DartPluginRegistrant.ensureInitialized();
  await ReminderService.handleResponse(response);
}

/// রিমাইন্ডারের নোটিফিকেশন শিডিউল ও Done/Not yet হ্যান্ডলিং।
///
/// * প্রতিটা রিমাইন্ডারের জন্য আগামী [_horizonDays] দিনের প্রতিটা সময়ের
///   আলাদা exact alarm বসানো হয় (রিপিট হলে প্রতিদিন যেগুলো ঘটার কথা)।
/// * অ্যাপ খুললে, resume হলে এবং প্রতি ৬ ঘণ্টায় WorkManager-এর মাধ্যমে
///   [rearmAll] চলে — তাই সময় গড়ালেও পরের দিনগুলোর অ্যালার্ম নতুন করে বসে।
/// * Done → সেই দিনের সব নোটিফিকেশন বন্ধ (এক-বারের হলে চিরতরে)।
/// * Not yet → [snoozeMinutes] মিনিট পর আবার মনে করাবে, Done না দেওয়া পর্যন্ত।
class ReminderService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const channelId = 'reminder_channel_v1';
  static const actionDone = 'rem_done';
  static const actionNotYet = 'rem_notyet';
  static const snoozeMinutes = 30;
  static const _horizonDays = 7;
  static const maxTimesPerReminder = 8;

  /// ডাটা বদলালে UI রিফ্রেশ করার জন্য।
  static final ValueNotifier<int> changes = ValueNotifier(0);

  /// নোটিফিকেশনের বডিতে ট্যাপ করলে HomeShell এটা দেখে Reminder স্ক্রিন খোলে।
  static final ValueNotifier<int> openRequest = ValueNotifier(0);

  /// ক্যাশবুকের সন্ধ্যার সতর্কতায় (payload 'cashbook_evening') ট্যাপ
  /// করলে HomeShell এটা দেখে ক্যাশবুক খোলে।
  static final ValueNotifier<int> cashbookOpenRequest = ValueNotifier(0);

  /// নোটিফিকেশনে ট্যাপ করে সরাসরি যাওয়ার গন্তব্য (payload)। HomeShell
  /// [targetRequest] শুনে [pendingTarget] পড়ে সংশ্লিষ্ট স্ক্রিন/সার্কুলার খোলে।
  static String? pendingTarget;
  static final ValueNotifier<int> targetRequest = ValueNotifier(0);

  /// শেষ ট্যাপ করা রিমাইন্ডারের id — সার্কুলারের রিমাইন্ডার হলে HomeShell
  /// রিমাইন্ডার স্ক্রিনের বদলে সরাসরি সেই সার্কুলার খোলে।
  static int? pendingReminderId;

  static void _requestTarget(String target) {
    pendingTarget = target;
    targetRequest.value++;
  }

  static int _baseId(int reminderId) => 100000000 + (reminderId % 1000000) * 1000;
  static int _snoozeId(int reminderId) => _baseId(reminderId) + 999;

  static String _payload(int id, String date, {bool snooze = false}) =>
      'rem|$id|$date${snooze ? '|snooze' : ''}';

  static Future<void> ensureReady() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final dynamic r = await FlutterTimezone.getLocalTimezone();
      final String name = r is String ? r : (r.identifier as String);
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {}
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: onForeground,
      onDidReceiveBackgroundNotificationResponse: reminderBackgroundHandler,
    );
    _ready = true;
  }

  /// অ্যাপ চলা অবস্থায় (foreground) নোটিফিকেশন রেসপন্স।
  static void onForeground(NotificationResponse r) {
    handleResponse(r);
  }

  static Future<void> handleResponse(NotificationResponse r) async {
    final p = r.payload;
    final bodyTap = r.actionId == null &&
        r.notificationResponseType ==
            NotificationResponseType.selectedNotification;
    if (p == 'cashbook_evening' || p == 'cashbook_guard') {
      if (bodyTap) cashbookOpenRequest.value++;
      return;
    }
    if (p != null && bodyTap) {
      if (p == 'job_radar' ||
          p.startsWith('job_item|') ||
          p.startsWith('job_admit') ||
          p == 'today_digest' ||
          p == 'vault_backup' ||
          p.startsWith('idea_') ||
          p.startsWith('project_')) {
        _requestTarget(p);
        return;
      }
    }
    if (p == null || !p.startsWith('rem|')) return;
    final parts = p.split('|');
    if (parts.length < 3) return;
    final id = int.tryParse(parts[1]);
    if (id == null) return;
    final date = parts[2];

    if (r.actionId == actionDone) {
      await ensureReady();
      await markDone(id, date);
    } else if (r.actionId == actionNotYet) {
      await ensureReady();
      await snooze(id, date);
    } else if (r.notificationResponseType ==
        NotificationResponseType.selectedNotification) {
      pendingReminderId = id;
      openRequest.value++;
    }
  }

  /// অ্যাপ ক্যাশবুকের সন্ধ্যার সতর্কতায় ট্যাপ করে কোল্ড-স্টার্ট হয়েছিল কি না।
  static Future<bool> launchedFromCashbook() async {
    final p = await launchedTarget();
    return p == 'cashbook_evening' || p == 'cashbook_guard';
  }

  /// কোল্ড-স্টার্টে নোটিফিকেশনের বডিতে ট্যাপ হয়ে থাকলে সেই payload —
  /// HomeShell এটা দিয়ে সরাসরি সংশ্লিষ্ট স্ক্রিন/সার্কুলার খোলে।
  static Future<String?> launchedTarget() async {
    try {
      await ensureReady();
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (!(d?.didNotificationLaunchApp ?? false)) return null;
      if (d?.notificationResponse?.actionId != null) return null;
      return d?.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> launchedReminderId() async {
    final p = await launchedTarget();
    if (p == null || !p.startsWith('rem|')) return null;
    final parts = p.split('|');
    return parts.length > 1 ? int.tryParse(parts[1]) : null;
  }

  /// অ্যাপ নোটিফিকেশনে ট্যাপ করে কোল্ড-স্টার্ট হয়েছিল কি না।
  static Future<bool> launchedFromReminder() async {
    try {
      await ensureReady();
      final d = await _plugin.getNotificationAppLaunchDetails();
      final payload = d?.notificationResponse?.payload;
      return (d?.didNotificationLaunchApp ?? false) &&
          payload != null &&
          payload.startsWith('rem|') &&
          d?.notificationResponse?.actionId == null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestPermissions() async {
    await ensureReady();
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await impl?.requestNotificationsPermission();
      await impl?.requestExactAlarmsPermission();
    } catch (_) {}
    try {
      final s = await Permission.ignoreBatteryOptimizations.status;
      if (!s.isGranted) await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- actions

  static Future<void> markDone(int id, String occurrenceDate) async {
    final r = await ReminderDB.getById(id);
    if (r != null) {
      if (!r.repeats) {
        r.done = true;
      } else {
        final prev = r.lastDoneDate;
        if (prev == null || occurrenceDate.compareTo(prev) > 0) {
          r.lastDoneDate = occurrenceDate;
        }
      }
      await ReminderDB.update(r);
    }
    await _cancelPending(id, keepSnooze: false);
    if (r != null && !r.done) await _scheduleOccurrences(r);
    changes.value++;
  }

  static Future<void> undoDone(Reminder r) async {
    r.done = false;
    r.lastDoneDate = null;
    await ReminderDB.update(r);
    await rearm(r);
    changes.value++;
  }

  static Future<void> stopSeries(Reminder r) async {
    r.done = true;
    await ReminderDB.update(r);
    await _cancelPending(r.id!, keepSnooze: false);
    changes.value++;
  }

  static Future<void> delete(int id) async {
    await ReminderDB.delete(id);
    await _cancelPending(id, keepSnooze: false);
    changes.value++;
  }

  static Future<void> snooze(int id, String occurrenceDate) async {
    final r = await ReminderDB.getById(id);
    if (r == null || r.done) return;
    final when = DateTime.now().add(const Duration(minutes: snoozeMinutes));
    await _schedule(
      notifId: _snoozeId(id),
      r: r,
      when: when,
      occurrenceDate: occurrenceDate,
      snoozed: true,
    );
  }

  // -------------------------------------------------------------- scheduling

  /// একটা রিমাইন্ডারের সব pending নোটিফিকেশন মুছে নতুন করে বসায়।
  static Future<void> rearm(Reminder r) async {
    await ensureReady();
    await _cancelPending(r.id!, keepSnooze: !r.done);
    if (!r.done) await _scheduleOccurrences(r);
  }

  /// সব রিমাইন্ডার নতুন করে শিডিউল — অ্যাপ স্টার্ট / resume / WorkManager থেকে।
  static Future<void> rearmAll() async {
    await ensureReady();
    final list = await ReminderDB.all();
    final byId = {for (final r in list) r.id!: r};

    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending) {
      final payload = p.payload;
      if (payload == null || !payload.startsWith('rem|')) continue;
      final parts = payload.split('|');
      final id = int.tryParse(parts.length > 1 ? parts[1] : '');
      final r = id == null ? null : byId[id];
      final isSnooze = parts.length > 3 && parts[3] == 'snooze';
      final keep = isSnooze &&
          r != null &&
          !r.done &&
          r.lastDoneDate != (parts.length > 2 ? parts[2] : '');
      if (!keep) await _plugin.cancel(p.id);
    }
    for (final r in list) {
      if (!r.done) await _scheduleOccurrences(r);
    }
  }

  static Future<void> _cancelPending(int reminderId,
      {required bool keepSnooze}) async {
    await ensureReady();
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending) {
      final payload = p.payload;
      if (payload == null) continue;
      if (!payload.startsWith('rem|$reminderId|')) continue;
      if (keepSnooze && payload.endsWith('|snooze')) continue;
      await _plugin.cancel(p.id);
    }
  }

  static Future<void> _scheduleOccurrences(Reminder r) async {
    final now = DateTime.now();
    final today = dateOnly(now);
    final times = r.times.take(maxTimesPerReminder).toList();
    // এক-বারের রিমাইন্ডার (যেমন সার্কুলারের "শেষ ৭ দিন বাকি") ৬০ দিন আগেই ফোনের অ্যালার্মে বসে যায় —
    // নইলে অ্যাপ না খুললে/ব্যাকগ্রাউন্ড টাস্ক না চললে ৭ দিনের বেশি দূরের তারিখের রিমাইন্ডার কখনো বাজতই না।
    // (প্রতিটার আইডির জায়গা ১০০০ — d*10+i সর্বোচ্চ ~৬০৭, সংঘর্ষ নেই।) পুনরাবৃত্ত রিমাইন্ডার আগের মতো ৭ দিন।
    final horizon = r.repeats ? _horizonDays : 60;
    for (var d = 0; d < horizon; d++) {
      final base = today.add(Duration(days: d));
      final day = DateTime(base.year, base.month, base.day);
      if (!r.occursOn(day)) continue;
      final dayStr = Reminder.ymd(day);
      if (r.lastDoneDate == dayStr) continue;
      for (var i = 0; i < times.length; i++) {
        final (h, m) = parseHm(times[i]);
        final at = DateTime(day.year, day.month, day.day, h, m);
        if (!at.isAfter(now)) continue;
        await _schedule(
          notifId: _baseId(r.id!) + d * 10 + i,
          r: r,
          when: at,
          occurrenceDate: dayStr,
        );
      }
    }
  }

  /// কোন ধরনের রিমাইন্ডারের জন্য কোন "action verb" — বডিটা যাতে শুকনো টাইটেলের
  /// পুনরাবৃত্তি না হয়ে, কী করতে হবে সেটা নিজে থেকেই বলে দেয়।
  static String _kindVerb(String kind) {
    switch (kind) {
      case 'post':
        return 'পোস্ট করার সময় হয়ে গেছে';
      case 'call':
        return 'কল করার সময় হয়ে গেছে';
      case 'give':
        return 'দেওয়ার কথা ছিল, ভুলে যেও না';
      case 'plan':
        return 'প্ল্যান অনুযায়ী আজকের কাজ';
      default:
        return 'মনে করিয়ে দিচ্ছি';
    }
  }

  /// টাইটেল + বডি — সময়/অবস্থা বুঝে ইমোজি ও ভাষা একটু বদলায়, যাতে
  /// শুধু একঘেয়ে "রিমাইন্ডার: শিরোনাম" না হয়ে একটু "স্মার্ট" লাগে।
  static (String, String) _smartContent(
      Reminder r, DateTime when, {required bool snoozed}) {
    final kind = kindOf(r.kind);
    final hour = when.hour;
    final greetEmoji = hour < 12
        ? '☀️'
        : hour < 17
            ? '🌤️'
            : hour < 20
                ? '🌆'
                : '🌙';

    final title = snoozed
        ? '🔔 রিমাইন্ডার (আবার মনে করাচ্ছি) • ${kind.emoji} ${r.title}'
        : '🔔 রিমাইন্ডার • ${kind.emoji} ${r.title}';

    final noteText = r.note.trim();
    final lead = snoozed
        ? '⏳ এখনো হয়নি? '
        : '$greetEmoji ${_kindVerb(r.kind)}. ';
    final tail = r.repeats ? '\n🔁 ${r.repeatLabel}' : '';
    final body = noteText.isNotEmpty
        ? '$lead\n📝 $noteText$tail'
        : '$lead$tail'.trim();

    return (title, body);
  }

  static Future<void> _schedule({
    required int notifId,
    required Reminder r,
    required DateTime when,
    required String occurrenceDate,
    bool snoozed = false,
  }) async {
    final (title, body) = _smartContent(r, when, snoozed: snoozed);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        'রিমাইন্ডার',
        channelDescription: 'আপনার নোট করা রিমাইন্ডারগুলো',
        importance: Importance.max,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        enableVibration: true,
        playSound: true,
        category: AndroidNotificationCategory.reminder,
        subText: 'রিমাইন্ডার',
        ticker: title,
        styleInformation: BigTextStyleInformation(
          body,
          contentTitle: title,
          summaryText: 'My Manager',
        ),
        actions: const [
          AndroidNotificationAction(actionDone, '✅ Done',
              cancelNotification: true, showsUserInterface: false),
          AndroidNotificationAction(actionNotYet, '⏳ Not yet',
              cancelNotification: true, showsUserInterface: false),
        ],
      ),
    );
    final tzTime = tz.TZDateTime.from(when, tz.local);
    final payload = _payload(r.id!, occurrenceDate, snooze: snoozed);
    try {
      await _plugin.zonedSchedule(
        notifId, title, body, tzTime, details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    } catch (_) {
      // exact alarm permission না থাকলে inexact-এ নামিয়ে আনি।
      try {
        await _plugin.zonedSchedule(
          notifId, title, body, tzTime, details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload,
        );
      } catch (e) {
        debugPrint('Reminder schedule failed: $e');
      }
    }
  }

  // ------------------------------------------------------------------- misc

  /// আজকের বাকি + মেয়াদ-পেরোনো রিমাইন্ডারের সংখ্যা (হোমের ব্যাজের জন্য)।
  static Future<int> pendingTodayCount() async {
    final today = dateOnly(DateTime.now());
    final list = await ReminderDB.all();
    return list.where((r) => r.isDueToday(today) || r.isOverdue(today)).length;
  }
}
