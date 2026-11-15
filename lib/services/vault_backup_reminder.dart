import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../reminder/services/reminder_service.dart';
import 'vault_backup_service.dart';
import 'vault_service.dart';

/// ভল্টের backup-বাকি সতর্কতা — নোটিফিকেশন বারে লেগে-থাকা (ongoing)
/// নোটিফিকেশন, ক্যাশবুক খরচ-প্রহরীর (আইডি ৭৮২০) মতোই ধাঁচে।
///
/// কেন: ব্যবহারকারীর সিদ্ধান্ত (২০২৬-১১-১৫) — backup password ফোনে
/// সেভ থাকবে না, তাই ভল্টের backup নিজে নিজে হতে পারে না। বদলে:
/// ভল্টে backup-না-হওয়া বদল থাকলেই এই সতর্কতা বসে থাকে; backup
/// নিলেই নিজে থেকে উঠে যায়। পাসওয়ার্ড প্রতিবার ব্যবহারকারী নিজে
/// দেন (ভল্ট স্ক্রিনের ব্যানার → এক ট্যাপে ব্যাকআপ শিট)।
///
/// [sync] সস্তা ও idempotent — অ্যাপ চালুতে, ভল্ট স্ক্রিন লোডে আর
/// Backup Center-এ ভল্ট শিট বন্ধ হলে ডাকা হয়।
class VaultBackupReminder {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _notifId = 7821;

  static Future<void> _init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // প্লাগইনটা অ্যাপ-জুড়ে একটাই — শেষ initialize() জেতে, তাই
    // রিমাইন্ডারের callback-গুলো এখানেও হুবহু বসাতে হয় (নইলে
    // রিমাইন্ডারের Done/Not yet বাটন ভেঙে যাবে)।
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: ReminderService.onForeground,
      onDidReceiveBackgroundNotificationResponse: reminderBackgroundHandler,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  }

  static Future<void> sync() async {
    try {
      final entries = await VaultService.getAll();
      final last = VaultBackupService.lastBackupMs();
      final changed = entries.where((e) => e.updatedAt > last).length;
      final needed = entries.isNotEmpty && (last == 0 || changed > 0);
      await _init();
      if (!needed) {
        await _plugin.cancel(_notifId);
        return;
      }
      final body = last == 0
          ? 'ভল্টের কোনো backup নেই — অ্যাপ মুছে গেলে সব পাসওয়ার্ড ও 2FA কোড হারাবে। ভল্ট খুলে backup নাও।'
          : 'শেষ backup-এর পর $changedটা এন্ট্রি নতুন/বদলেছে — backup না নিলে অ্যাপ মুছে গেলে ওগুলো হারাবে। ভল্ট খুলে backup নাও।';
      const details = AndroidNotificationDetails(
        'vault_backup_channel',
        'ভল্ট ব্যাকআপ সতর্কতা',
        channelDescription: 'ভল্টে backup-না-হওয়া পরিবর্তন থাকলে স্থায়ী সতর্কতা',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFF59E0B),
        colorized: true,
        category: AndroidNotificationCategory.reminder,
        ongoing: true,
        autoCancel: false,
      );
      await _plugin.show(
          _notifId, '🔐 ভল্টের backup বাকি', body, const NotificationDetails(android: details));
    } catch (_) {
      // সতর্কতা বসানো ব্যর্থ হলে অ্যাপের কাজ থামবে না — ভল্ট স্ক্রিনের
      // ব্যানার তো আছেই।
    }
  }
}
