import '../cashbook/services/cashbook_backup_service.dart';
import '../family/services/family_backup_service.dart';
import '../jobs/services/job_backup_service.dart';
import '../reminder/services/reminder_backup_service.dart';
import 'drive_service.dart';
import 'settings_service.dart';
import 'vault_backup_service.dart';

/// সব Drive মডিউলের অটো-ব্যাকআপের একক পথ — WorkManager টাস্ক আর
/// অ্যাপ-শুরুর catch-up দুটোই এটা ডাকে। প্রতিটা রানের ফল (কখন, সফল
/// না ব্যর্থ, কোন মডিউল ব্যর্থ) prefs-এ লেখা থাকে, যাতে Backup
/// Center-এ চোখে দেখে যাচাই করা যায় — নীরব ব্যর্থতা আর নয়।
/// ভল্ট: সংরক্ষিত পাসওয়ার্ড থাকলেই অটো-ব্যাকআপে যোগ হয়
/// (ব্যবহারকারীর নির্দেশ ২০২৬-১১-১৭); পাসওয়ার্ড না থাকলে ভল্ট
/// এই রানে থাকে না — সেটা ব্যর্থতা নয়, reminder পথ তখনো চালু।
/// ডকুমেন্ট ভল্ট এখানে নেই: ওটার ব্যাকআপ হাতে নিতে হয়।
class AutoBackup {
  static const _kMs = 'auto_backup_last_ms';
  static const _kOk = 'auto_backup_last_ok';
  static const _kDetail = 'auto_backup_last_detail';

  static int get lastMs => SettingsService.getInt(_kMs);
  static bool get lastOk => SettingsService.getBool(_kOk);
  static String get lastDetail => SettingsService.getString(_kDetail);

  static Future<void> _record(bool ok, String detail) async {
    await SettingsService.setInt(_kMs, DateTime.now().millisecondsSinceEpoch);
    await SettingsService.setBool(_kOk, ok);
    await SettingsService.setString(_kDetail, detail);
  }

  /// সব মডিউল ব্যাকআপ করে; সব সফল হলে true। সেটিং বন্ধ থাকলে false।
  static Future<bool> runAll() async {
    if (!SettingsService.getBool('auto_backup_enabled', defaultValue: true)) {
      return false;
    }
    final drive = DriveService.instance;
    if (!await drive.signInSilently()) {
      var err = drive.lastError ?? '';
      if (err.length > 90) err = '${err.substring(0, 90)}…';
      await _record(
          false, err.isEmpty ? 'Google সাইন-ইন হয়নি' : 'সাইন-ইন হয়নি: $err');
      return false;
    }
    final results = <String, bool>{};
    Future<void> one(String name, Future<DriveBackupResult> f) async {
      try {
        results[name] = await f == DriveBackupResult.success;
      } catch (_) {
        results[name] = false;
      }
    }

    await one('প্রজেক্ট', drive.backupDatabase());
    await one('ক্যাশবুক', CashbookBackupService.backupNow());
    await one('চাকরি', JobBackupService.backupNow());
    await one('পরিবার', FamilyBackupService.backupNow());
    await one('রিমাইন্ডার', ReminderBackupService.backupNow());
    // ভল্ট — সংরক্ষিত পাসওয়ার্ড থাকলেই (উপরে দ্রষ্টব্য)।
    final vaultPw = await VaultBackupService.autoPassword();
    if (vaultPw != null) {
      await one(
          'ভল্ট',
          VaultBackupService.backupToDrive(vaultPw).then((r) =>
              r == VaultDriveResult.success
                  ? DriveBackupResult.success
                  : DriveBackupResult.failed));
    }
    final failed = results.entries.where((e) => !e.value).map((e) => e.key).toList();
    if (failed.isEmpty) {
      await _record(true, 'সব মডিউল (${results.length}টি) সফল');
      return true;
    }
    await _record(false, 'ব্যর্থ: ${failed.join(', ')}');
    return false;
  }

  /// অ্যাপ খোলার সময়: শেষ রান ১২ ঘণ্টার বেশি পুরনো হলে এখনই একবার
  /// চালায় — WorkManager পিছিয়ে গেলেও লম্বা ফাঁক থাকে না।
  static Future<void> runIfDue() async {
    try {
      if (!SettingsService.getBool('auto_backup_enabled', defaultValue: true)) return;
      final last = lastMs;
      final stale = last == 0 ||
          DateTime.now().millisecondsSinceEpoch - last >
              const Duration(hours: 12).inMilliseconds;
      if (stale) await runAll();
    } catch (_) {}
  }
}
