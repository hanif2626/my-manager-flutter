import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../cashbook/db/cashbook_db.dart';
import '../../cashbook/models/cashbook_entry.dart';
import '../../reminder/db/reminder_db.dart';
import '../../reminder/models/reminder.dart';
import '../../reminder/services/reminder_service.dart';
import '../../services/settings_service.dart';
import '../db/job_db.dart';
import '../models/job_models.dart';
import '../radar/radar_service.dart' show RadarService;
import 'job_backup_service.dart';

/// চাকরি হাবের লজিক। সার্কুলারের তারিখ থেকে রিমাইন্ডার নিজে তৈরি হয় —
/// বিদ্যমান রিমাইন্ডার ইঞ্জিন (নোটিফিকেশন, Done/Not yet, স্নুজ) ব্যবহার করে,
/// তাই রিমাইন্ডার স্ক্রিনেও এগুলো দেখা যায়।
class JobService {
  static final ValueNotifier<int> changes = ValueNotifier(0);

  /// UI রিফ্রেশ + Drive-এ চুপচাপ ব্যাকআপ (ডিবাউন্সড)।
  static void _notify() {
    changes.value++;
    JobBackupService.backupSilently();
  }

  static const _profileKeys = [
    _kPost, _kGrade, _kSalary, _kAgeOut, _kExamName, _kExamDate,
    ...RadarService.backupKeys, // রাডারের প্রোফাইল (টোকেন বাদে)
  ];

  static Map<String, String> profileMap() => {
        for (final k in _profileKeys) k: SettingsService.getString(k),
      };

  /// ব্যাকআপ থেকে প্রোফাইল ফেরত — লোকালে যেটা ফাঁকা শুধু সেটাই ভরে।
  static Future<void> restoreProfile(Map<String, dynamic> m) async {
    for (final k in _profileKeys) {
      final v = m[k];
      if (v is String && v.isNotEmpty && SettingsService.getString(k).isEmpty) {
        await SettingsService.setString(k, v);
      }
    }
  }

  // ── প্রোফাইল (SharedPreferences) ──
  static const _kPost = 'job_target_post';
  static const _kGrade = 'job_target_grade';
  static const _kSalary = 'job_target_salary';
  static const _kAgeOut = 'job_age_out';
  static const _kExamName = 'job_exam_name';
  static const _kExamDate = 'job_exam_date';
  static const _kWeeklyOn = 'job_weekly_on';
  static const _kWeeklyRem = 'job_weekly_rem';

  static String get targetPost => SettingsService.getString(_kPost);
  static String get targetGrade => SettingsService.getString(_kGrade);
  static String get targetSalary => SettingsService.getString(_kSalary);
  static String get examName => SettingsService.getString(_kExamName);

  static Future<void> setTarget(String post, String grade, String salary) async {
    await SettingsService.setString(_kPost, post);
    await SettingsService.setString(_kGrade, grade);
    await SettingsService.setString(_kSalary, salary);
    _notify();
  }

  static DateTime? _date(String key) {
    final s = SettingsService.getString(key);
    return s.isEmpty ? null : Reminder.parseYmd(s);
  }

  static DateTime? get ageOut => _date(_kAgeOut);
  static DateTime? get examDate => _date(_kExamDate);

  static Future<void> setAgeOut(DateTime? d) async {
    await SettingsService.setString(_kAgeOut, d == null ? '' : Reminder.ymd(d));
    _notify();
  }

  static Future<void> setExam(String name, DateTime? d) async {
    await SettingsService.setString(_kExamName, name);
    await SettingsService.setString(_kExamDate, d == null ? '' : Reminder.ymd(d));
    _notify();
  }

  // ── সার্কুলার ──
  static Future<List<Circular>> circulars() async {
    final list = await JobDB.all();
    // সক্রিয় (আবেদন বাকি) আগে, ডেডলাইন কাছের থেকে; তারপর বাকিগুলো নতুন আগে।
    list.sort((a, b) {
      int rank(Circular c) => c.needsAction ? 0 : (c.status == 'closed' ? 2 : 1);
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      if (rank(a) == 0) return a.deadline!.compareTo(b.deadline!);
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  static Future<void> saveCircular(Circular c) async {
    if (c.id == null) {
      c.id = await JobDB.insert(c);
    }
    await _syncReminders(c);
    await JobDB.update(c);
    _notify();
  }

  /// অবস্থা বদলায়। আবেদন করা হয়ে গেলে (আবেদন করেছি বা তার পরের ধাপ) আবেদন ফি নিজে ক্যাশবুকে
  /// খরচ হিসেবে যোগ হয়; "নজরে"-তে ফেরালে ওই এন্ট্রি মুছে যায়। ফেরত দেয় ব্যবহারকারীকে দেখানোর বার্তা।
  static Future<String?> setStatus(Circular c, String status) async {
    c.status = status;
    await saveCircular(c);
    try {
      return await _syncFeeLedger(c);
    } catch (_) {
      return null; // ক্যাশবুকে লিখতে না পারলেও সার্কুলারের অবস্থা বদল আটকাবে না
    }
  }

  static const _feeKey = 'job_fee_entries'; // {"সার্কুলার-id": এন্ট্রি-id}
  static const _paidStatuses = {'applied', 'admit', 'exam_done', 'result'};

  static Map<String, dynamic> _feeMap() {
    try {
      return Map<String, dynamic>.from(jsonDecode(SettingsService.getString(_feeKey)) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<String?> _syncFeeLedger(Circular c) async {
    if (c.id == null) return null;
    final map = _feeMap();
    final key = '${c.id}';

    if (_paidStatuses.contains(c.status) && c.fee > 0 && !map.containsKey(key)) {
      final acc = await CashbookDB.currentMonthAccount();
      final now = DateTime.now();
      final ms = now.millisecondsSinceEpoch;
      final label = c.post.isNotEmpty ? '${c.title} (${c.post})' : c.title;
      final entryId = await CashbookDB.insertEntry(CashbookEntry(
        accountId: acc.id!,
        type: 'out',
        amount: c.fee.toDouble(),
        category: 'other',
        note: 'আবেদন ফি: $label',
        date: Reminder.ymd(now),
        createdAt: ms,
        updatedAt: ms,
      ));
      map[key] = entryId;
      try {
        await SettingsService.setString(_feeKey, jsonEncode(map));
      } catch (_) {
        await CashbookDB.deleteEntry(entryId);
        rethrow;
      }
      return '💰 আবেদন ফি ৳${bn(c.fee)} ক্যাশবুকে খরচ হিসেবে যোগ হয়েছে';
    }

    // আবার "নজরে (আবেদন বাকি)"-তে ফেরালে — ফি দেওয়া হয়নি ধরে এন্ট্রি মুছে ফেলা।
    if (c.status == 'watching' && map.containsKey(key)) {
      final eid = map.remove(key);
      if (eid != null) await CashbookDB.deleteEntry((eid as num).toInt());
      await SettingsService.setString(_feeKey, jsonEncode(map));
      return 'আবেদন ফির খরচের এন্ট্রি ক্যাশবুক থেকে মুছে ফেলা হয়েছে';
    }
    return null;
  }

  static Future<void> deleteCircular(Circular c) async {
    await _deleteReminders(c.deadlineRem);
    await _deleteReminders(c.examRem);
    if (c.id != null) {
      await JobDB.delete(c.id!);
      // ক্যাশবুকের খরচ (টাকা সত্যিই গেছে) থাকবে, শুধু যোগসূত্র মোছা।
      final m = _feeMap();
      if (m.remove('${c.id}') != null) await SettingsService.setString(_feeKey, jsonEncode(m));
    }
    _notify();
  }

  static Future<void> _deleteReminders(List<int> ids) async {
    for (final id in ids) {
      try {
        await ReminderService.delete(id);
      } catch (_) {}
    }
  }

  static Future<int> _mk(String title, String note, DateTime date, List<String> times) async {
    final r = Reminder(title: title, note: note, kind: 'plan', date: date, times: times);
    r.id = await ReminderDB.insert(r);
    await ReminderService.rearm(r);
    ReminderService.changes.value++;
    return r.id!;
  }

  /// সার্কুলারের তারিখ/অবস্থা বদলালে পুরোনো রিমাইন্ডার মুছে নতুন বানায়।
  ///  • আবেদনের ডেডলাইন: ৭, ৩, ১ দিন আগে ও শেষ দিনে (শুধু আবেদন বাকি থাকলে)
  ///  • পরীক্ষা: ৭, ৩, ১ দিন আগে ও পরীক্ষার দিন সকালে
  static Future<void> _syncReminders(Circular c) async {
    await _deleteReminders(c.deadlineRem);
    await _deleteReminders(c.examRem);
    c.deadlineRem = [];
    c.examRem = [];

    final today = dateOnly(DateTime.now());
    final label = c.post.isNotEmpty ? '${c.title} (${c.post})' : c.title;
    final feeNote = c.fee > 0 ? ' · ফি ${bn(c.fee)} টাকা' : '';

    if (c.status == 'watching' && c.deadline != null) {
      final dl = dateOnly(c.deadline!);
      for (final off in const [7, 3, 1, 0]) {
        final d = dl.subtract(Duration(days: off));
        if (d.isBefore(today)) continue;
        final title = off == 0
            ? '🚨 আজই আবেদনের শেষ দিন: $label'
            : '⏳ আবেদনের শেষ ${bn(off)} দিন বাকি: $label';
        final note = 'শেষ তারিখ ${formatDateBn(dl)}$feeNote'
            '${c.url.isNotEmpty ? '\nলিংক: ${c.url}' : ''}';
        c.deadlineRem.add(await _mk(title, note, d, off == 0 ? ['08:00', '16:00'] : ['08:00']));
      }
    }

    if (c.examDate != null && c.status != 'closed' && c.status != 'result') {
      final ex = dateOnly(c.examDate!);
      for (final off in const [7, 3, 1, 0]) {
        final d = ex.subtract(Duration(days: off));
        if (d.isBefore(today)) continue;
        final title = off == 0
            ? '📝 আজ পরীক্ষা: $label'
            : '📅 পরীক্ষার আর ${bn(off)} দিন: $label';
        final note = 'পরীক্ষা ${formatDateBn(ex)}'
            '${off <= 1 ? '\nপ্রবেশপত্র, কলম, ছবিসহ কাগজপত্র গুছিয়ে নাও' : ''}';
        c.examRem.add(await _mk(title, note, d, off == 0 ? ['06:30'] : ['08:00']));
      }
    }
  }

  // ── ডকুমেন্ট ──
  static Future<List<JobDoc>> docs() => JobDB.docs();
  static Future<void> addDoc(String title) async {
    await JobDB.insertDoc(title);
    _notify();
  }

  static Future<void> setDocDone(JobDoc d, bool done) async {
    d.done = done;
    await JobDB.setDocDone(d.id!, done);
    _notify();
  }

  static Future<void> deleteDoc(JobDoc d) async {
    await JobDB.deleteDoc(d.id!);
    _notify();
  }

  // ── সাপ্তাহিক রিভিউ ──
  static bool get weeklyOn => SettingsService.getBool(_kWeeklyOn);

  static Future<void> setWeekly(bool on) async {
    final old = SettingsService.getInt(_kWeeklyRem, defaultValue: 0);
    if (old != 0) {
      try {
        await ReminderService.delete(old);
      } catch (_) {}
      await SettingsService.setInt(_kWeeklyRem, 0);
    }
    if (on) {
      final now = DateTime.now();
      var d = dateOnly(now);
      while (d.weekday != DateTime.friday || (d == dateOnly(now) && now.hour >= 20)) {
        d = d.add(const Duration(days: 1));
      }
      final r = Reminder(
        title: '🗓️ সাপ্তাহিক রিভিউ',
        note: 'এই সপ্তাহে কী পড়লাম? কী বাকি? কোন সার্কুলারে কাজ বাকি? পরের সপ্তাহের লক্ষ্য কী?',
        kind: 'plan',
        date: d,
        times: ['20:00'],
        repeat: 'weekly',
      );
      r.id = await ReminderDB.insert(r);
      await ReminderService.rearm(r);
      ReminderService.changes.value++;
      await SettingsService.setInt(_kWeeklyRem, r.id!);
    }
    await SettingsService.setBool(_kWeeklyOn, on);
    _notify();
  }
}
