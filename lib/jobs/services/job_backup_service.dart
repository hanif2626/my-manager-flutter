import 'dart:async';
import 'dart:convert';
import '../../services/additive_merge.dart';
import '../../services/drive_service.dart';
import '../db/job_db.dart';
import '../models/job_models.dart';
import 'job_service.dart';

/// চাকরি হাবের ডাটা (সার্কুলার, ডকুমেন্ট চেকলিস্ট, টার্গেট/কাউন্টডাউন)
/// Google Drive-এর MyManager_Backup ফোল্ডারে jobs_backup.json-এ সেভ হয়।
///
///  • প্রতিবার কিছু বদলালে চুপচাপ ব্যাকআপ (৪ সেকেন্ড অপেক্ষা করে একসাথে),
///    Drive সাইন-ইন না থাকলে কিছু করে না — ক্যাশবুকের মতো একই ধরন।
///  • রিস্টোর মার্জ করে, বর্তমান কিছু মুছে না। সার্কুলারের রিমাইন্ডার
///    ব্যাকআপে রাখা হয় না — রিস্টোরের সময় তারিখ থেকে নতুন করে বানানো হয়।
class JobBackupService {
  static const fileName = 'jobs_backup.json';
  static DateTime? lastBackupAt;
  static Timer? _timer;

  static Future<String> _exportJson() async {
    final circulars = await JobDB.all();
    final docs = await JobDB.docs();
    return jsonEncode({
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'circulars': circulars.map((c) {
        final m = c.toMap();
        m.remove('id');
        m['deadline_rem'] = '';
        m['exam_rem'] = '';
        return m;
      }).toList(),
      'docs': docs.map((d) => {'title': d.title, 'done': d.done, 'sort': d.sort}).toList(),
      'profile': JobService.profileMap(),
    });
  }

  /// পরিবর্তনের পর ডাকা হয়; কয়েকটা পরিবর্তন জমিয়ে একবারই আপলোড করে।
  static void backupSilently() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () async {
      final drive = DriveService.instance;
      if (!drive.isSignedIn) return;
      try {
        // Additive: Drive-এর আগের কপির সাথে মার্জ করে তবে আপলোড।
        final r = await drive.backupJson(fileName, await _exportJson(),
            merge: AdditiveMerge.mergeJobs);
        if (r == DriveBackupResult.success) lastBackupAt = DateTime.now();
      } catch (_) {
        // সাইলেন্ট ব্যাকআপ কখনো ব্যবহারকারীর কাজ আটকাবে না।
      }
    });
  }

  static Future<bool> _ensureDrive() async {
    final ds = DriveService.instance;
    if (ds.isSignedIn) return true;
    if (await ds.signInSilently()) return true;
    return ds.signIn();
  }

  /// হাতে-চালানো ব্যাকআপ (ফলাফল দেখানোর জন্য)।
  static Future<DriveBackupResult> backupNow() async {
    if (!await _ensureDrive()) return DriveBackupResult.notSignedIn;
    final r = await DriveService.instance.backupJson(fileName, await _exportJson(),
        merge: AdditiveMerge.mergeJobs);
    if (r == DriveBackupResult.success) lastBackupAt = DateTime.now();
    return r;
  }

  /// রিস্টোর: (নতুন সার্কুলার, নতুন/আপডেট ডকুমেন্ট) সংখ্যা; null → ব্যাকআপ নেই/ব্যর্থ।
  static Future<({int circulars, int docs})?> restoreFromDrive({BackupVersion? version}) async {
    if (!await _ensureDrive()) return null;
    final text = await DriveService.instance.restoreJson(fileName, version: version);
    if (text == null || text.isEmpty) return null;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    // সার্কুলার: একই শিরোনাম+পদ+শেষ তারিখ থাকলে বাদ, নয়তো যোগ (রিমাইন্ডারসহ)।
    final existing = await JobDB.all();
    String sig(String t, String p, String? d) => '$t\u0001$p\u0001${d ?? ''}';
    final have = existing
        .map((c) => sig(c.title, c.post, c.deadline == null ? null : c.toMap()['deadline'] as String?))
        .toSet();
    var addedC = 0;
    for (final raw in (data['circulars'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      m['id'] = 0;
      m['deadline_rem'] = '';
      m['exam_rem'] = '';
      final c = Circular.fromMap(m)..id = null;
      final key = sig(c.title, c.post, m['deadline'] as String?);
      if (have.contains(key)) continue;
      have.add(key);
      await JobService.saveCircular(c); // নতুন id + রিমাইন্ডার নতুন করে
      addedC++;
    }

    // ডকুমেন্ট: শিরোনাম মিললে টিক মার্জ, নয়তো যোগ।
    final docs = await JobDB.docs();
    final byTitle = {for (final d in docs) d.title: d};
    var changedD = 0;
    for (final raw in (data['docs'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final title = m['title'] as String;
      final done = m['done'] == true;
      final cur = byTitle[title];
      if (cur == null) {
        final id = await JobDB.insertDoc(title);
        if (done) await JobDB.setDocDone(id, true);
        changedD++;
      } else if (done && !cur.done) {
        await JobDB.setDocDone(cur.id!, true);
        changedD++;
      }
    }

    // প্রোফাইল: লোকালে ফাঁকা থাকলেই ভরে।
    final profile = data['profile'];
    if (profile is Map) {
      await JobService.restoreProfile(Map<String, dynamic>.from(profile));
    }
    JobService.changes.value++;
    return (circulars: addedC, docs: changedD);
  }
}
