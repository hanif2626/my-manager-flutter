import 'dart:async';
import 'dart:convert';
import '../../services/additive_merge.dart';
import '../../services/drive_service.dart';
import '../db/family_db.dart';
import '../models/family_models.dart';
import 'family_service.dart';

/// পরিবার মডিউলের ডাটা Google Drive-এর MyManager_Backup ফোল্ডারে
/// family_backup.json-এ। পরিবর্তনের ৪ সেকেন্ড পর চুপচাপ ব্যাকআপ (Drive
/// সাইন-ইন থাকলে); রিস্টোর মার্জ করে, কিছু মুছে না। রিমাইন্ডার ব্যাকআপে
/// রাখা হয় না — রিস্টোরের সময় তারিখ/বিল থেকে নতুন করে বানানো হয়।
class FamilyBackupService {
  static const fileName = 'family_backup.json';
  static DateTime? lastBackupAt;
  static Timer? _timer;

  static Future<String> _exportJson() async {
    final members = await FamilyDB.members();
    final dates = await FamilyDB.dates();
    final bills = await FamilyDB.bills();
    final contacts = await FamilyDB.contacts();
    Map<String, dynamic> strip(Map<String, dynamic> m, [List<String> clear = const []]) {
      final c = Map<String, dynamic>.from(m)..remove('id');
      for (final k in clear) {
        c[k] = '';
      }
      return c;
    }

    return jsonEncode({
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'members': members.map((m) => strip(m.toMap(), ['bday_rem'])).toList(),
      'dates': dates.map((d) => strip(d.toMap(), ['rem'])).toList(),
      'bills': bills.map((b) => strip(b.toMap(), ['rem'])).toList(),
      'contacts': contacts.map((c) => strip(c.toMap())).toList(),
    });
  }

  static void backupSilently() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () async {
      final drive = DriveService.instance;
      if (!drive.isSignedIn) return;
      try {
        // Additive: Drive-এর আগের কপির সাথে মার্জ করে তবে আপলোড।
        final r = await drive.backupJson(fileName, await _exportJson(),
            merge: AdditiveMerge.mergeFamily);
        if (r == DriveBackupResult.success) lastBackupAt = DateTime.now();
      } catch (_) {}
    });
  }

  static Future<bool> _ensureDrive() async {
    final ds = DriveService.instance;
    if (ds.isSignedIn) return true;
    if (await ds.signInSilently()) return true;
    return ds.signIn();
  }

  static Future<DriveBackupResult> backupNow() async {
    if (!await _ensureDrive()) return DriveBackupResult.notSignedIn;
    final r = await DriveService.instance.backupJson(fileName, await _exportJson(),
        merge: AdditiveMerge.mergeFamily);
    if (r == DriveBackupResult.success) lastBackupAt = DateTime.now();
    return r;
  }

  /// রিস্টোর: নতুন যোগ হওয়া (সদস্য, তারিখ, বিল, জরুরি) সংখ্যা; null → ব্যাকআপ নেই।
  static Future<({int members, int dates, int bills, int contacts})?> restoreFromDrive({BackupVersion? version}) async {
    if (!await _ensureDrive()) return null;
    final text = await DriveService.instance.restoreJson(fileName, version: version);
    if (text == null || text.isEmpty) return null;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    Iterable<Map<String, dynamic>> rows(String key) => (data[key] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map));

    // সদস্য: নাম + জন্মতারিখ মিললে বাদ।
    final haveM = (await FamilyDB.members()).map((m) => '${m.name}\u0001${m.toMap()['birth_date'] ?? ''}').toSet();
    var addedM = 0;
    for (final m in rows('members')) {
      m['id'] = 0;
      m['bday_rem'] = '';
      final x = FamilyMember.fromMap(m)..id = null;
      final key = '${x.name}\u0001${m['birth_date'] ?? ''}';
      if (haveM.contains(key)) continue;
      haveM.add(key);
      await FamilyService.saveMember(x);
      addedM++;
    }

    // তারিখ: শিরোনাম + মূল তারিখ।
    final haveD = (await FamilyDB.dates()).map((d) => '${d.title}\u0001${d.toMap()['date']}').toSet();
    var addedD = 0;
    for (final m in rows('dates')) {
      m['id'] = 0;
      m['rem'] = '';
      final x = FamilyDate.fromMap(m)..id = null;
      final key = '${x.title}\u0001${m['date']}';
      if (haveD.contains(key)) continue;
      haveD.add(key);
      await FamilyService.saveDate(x);
      addedD++;
    }

    // বিল: শিরোনাম + ডিউ ডে।
    final haveB = (await FamilyDB.bills()).map((b) => '${b.title}\u0001${b.dueDay}').toSet();
    var addedB = 0;
    for (final m in rows('bills')) {
      m['id'] = 0;
      m['rem'] = '';
      final x = FamilyBill.fromMap(m)..id = null;
      final key = '${x.title}\u0001${x.dueDay}';
      if (haveB.contains(key)) continue;
      haveB.add(key);
      await FamilyService.saveBill(x);
      addedB++;
    }

    // জরুরি তথ্য: নাম + ফোন।
    final haveC = (await FamilyDB.contacts()).map((c) => '${c.name}\u0001${c.phone}').toSet();
    var addedC = 0;
    for (final m in rows('contacts')) {
      m['id'] = 0;
      final x = FamilyContact.fromMap(m)..id = null;
      final key = '${x.name}\u0001${x.phone}';
      if (haveC.contains(key)) continue;
      haveC.add(key);
      await FamilyService.saveContact(x);
      addedC++;
    }

    FamilyService.changes.value++;
    return (members: addedM, dates: addedD, bills: addedB, contacts: addedC);
  }
}
