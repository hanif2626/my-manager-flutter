import 'dart:convert';
import '../../services/additive_merge.dart';
import '../../services/drive_service.dart';
import '../../today/today_service.dart';
import '../db/reminder_db.dart';
import '../models/reminder.dart';
import 'reminder_service.dart';

/// রিমাইন্ডারের Drive ব্যাকআপ (reminders_backup.json)।
///
/// চাকরি হাব ও পরিবার মডিউল নিজেদের তারিখ-বিল-সার্কুলার থেকে যেসব রিমাইন্ডার
/// বানায় সেগুলো এখানে নেওয়া হয় না — ওই মডিউলের রিস্টোর সেগুলো নিজেই নতুন করে
/// বানায়, নইলে ডুপ্লিকেট হতো। এখানে শুধু তোমার নিজের হাতে বানানো রিমাইন্ডার।
/// রিস্টোর মার্জ করে (একই শিরোনাম+তারিখ+সময়+রিপিট থাকলে বাদ), কিছু মুছে না।
class ReminderBackupService {
  static const fileName = 'reminders_backup.json';

  static String _sig(Reminder r) => '${r.title}\u0001${Reminder.ymd(r.date)}\u0001${r.times.join(',')}\u0001${r.repeat}';

  static Future<String> _export() async {
    final all = await ReminderDB.all();
    final managed = await TodayService.managedReminderIds(includeWeekly: true);
    final mine = all.where((r) => r.id == null || !managed.contains(r.id)).toList();
    return jsonEncode({
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'reminders': mine.map((r) {
        final m = r.toMap();
        m.remove('id');
        return m;
      }).toList(),
    });
  }

  static Future<DriveBackupResult> backupNow() async {
    final drive = DriveService.instance;
    if (!await drive.ensureSignedIn(interactive: true)) return DriveBackupResult.notSignedIn;
    // Additive: Drive-এর আগের কপির সাথে মার্জ করে তবে আপলোড।
    return drive.backupJson(fileName, await _export(),
        merge: AdditiveMerge.mergeReminders);
  }

  /// নতুন যোগ হওয়া সংখ্যা; null → ব্যাকআপ নেই/সাইন-ইন নেই।
  static Future<int?> restoreFromDrive({BackupVersion? version}) async {
    final drive = DriveService.instance;
    final text = await drive.restoreJson(fileName, version: version);
    if (text == null || text.isEmpty) return null;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final have = (await ReminderDB.all()).map(_sig).toSet();
    var added = 0;
    for (final raw in (data['reminders'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      m['id'] = 0;
      final r = Reminder.fromMap(m)..id = null;
      final key = _sig(r);
      if (have.contains(key)) continue;
      have.add(key);
      r.id = await ReminderDB.insert(r);
      await ReminderService.rearm(r);
      added++;
    }
    ReminderService.changes.value++;
    return added;
  }
}
