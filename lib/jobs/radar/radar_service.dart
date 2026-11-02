import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../reminder/models/reminder.dart' show Reminder;
import '../../services/settings_service.dart';
import '../models/job_models.dart';
import 'engine/match_engine.dart';
import 'engine/teletalk_source.dart';
import 'radar_models.dart';

/// Job Radar-এর প্রোফাইল, সেটিংস, ক্যাশ ও রূপান্তর। (সবকিছু ফোনের ভেতরে — কোনো সার্ভার/টোকেন লাগে না।)
class RadarService {
  // SharedPreferences কী — সবই স্ট্রিং, যাতে ব্যাকআপে সহজে যায়
  static const kDob = 'radar_dob';
  static const kEdu = 'radar_edu';
  static const kSubject = 'radar_subject';
  static const kTypBn = 'radar_typ_bn';
  static const kTypEn = 'radar_typ_en';
  static const kDaily = 'radar_daily_on'; // '1' / '0'
  static const kReportTime = 'radar_report_time'; // 'HH:mm'
  static const kInstant = 'radar_instant_on'; // নতুন যোগ্য সার্কুলার এলেই জানানো '1' / '0'
  static const kDeadline = 'radar_deadline_on'; // শেষ তারিখ ঘনিয়ে এলে জানানো '1' / '0'
  static const _kBgLog = 'radar_bg_log'; // ব্যাকগ্রাউন্ড চেকের শেষ কয়েকটা ফলাফল (সমস্যা ধরতে)
  static const kKwInclude = 'radar_kw_include'; // JSON তালিকা — যে পদগুলো খুঁজবে
  static const kKwExclude = 'radar_kw_exclude'; // JSON তালিকা — যেগুলো বাদ
  static const _kCache = 'radar_cache';
  static const _kDismissed = 'radar_dismissed';

  /// ব্যাকআপে যাবে এমন কী।
  static const backupKeys = [kDob, kEdu, kSubject, kTypBn, kTypEn, kDaily, kReportTime, kInstant, kDeadline, kKwInclude, kKwExclude, 'admit_watch_on', 'radar_starred', 'job_tags'];

  static const eduLevels = <String, String>{
    'ssc': 'এসএসসি / সমমান',
    'hsc': 'এইচএসসি / সমমান',
    'degree_pass': 'স্নাতক (পাস কোর্স, ৩ বছর)',
    'honours': 'স্নাতক (সম্মান)',
    'masters': 'স্নাতকোত্তর',
  };
  static const _eduRank = {'ssc': 2, 'hsc': 3, 'degree_pass': 4, 'honours': 5, 'masters': 6};

  // ── প্রোফাইল ──
  static String get dob => SettingsService.getString(kDob, defaultValue: '1999-01-01');
  static String get eduLevel => SettingsService.getString(kEdu, defaultValue: 'degree_pass');
  static String get subject => SettingsService.getString(kSubject);
  static int get typingBn => int.tryParse(SettingsService.getString(kTypBn)) ?? 20;
  static int get typingEn => int.tryParse(SettingsService.getString(kTypEn)) ?? 20;

  // ── রাতের রিপোর্ট ──
  static bool get dailyOn => SettingsService.getString(kDaily, defaultValue: '1') != '0';
  static String get reportTime => SettingsService.getString(kReportTime, defaultValue: '21:00');
  static int get reportHour => int.tryParse(reportTime.split(':').first) ?? 21;
  static int get reportMinute => int.tryParse(reportTime.split(':').last) ?? 0;

  // ── শেষ তারিখ ঘনিয়ে এলে জানানো ──
  static bool get deadlineOn => SettingsService.getString(kDeadline, defaultValue: '1') != '0';

  // ── ব্যাকগ্রাউন্ড চেকের লগ: ফোন ব্যাকগ্রাউন্ডে অ্যাপ চালাতে দিচ্ছে কি না বোঝার জন্য ──
  static List<String> bgLog() {
    final raw = SettingsService.getString(_kBgLog);
    if (raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> addBgLog(String msg) async {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line = '${n.day}/${n.month} ${two(n.hour)}:${two(n.minute)} — $msg';
    final list = [line, ...bgLog()].take(6).toList();
    await SettingsService.setString(_kBgLog, jsonEncode(list));
  }

  // ── নতুন সার্কুলার এলেই জানানো ──
  static bool get instantOn => SettingsService.getString(kInstant, defaultValue: '1') != '0';

  // ── খোঁজার পদ (নিজে বদলানো যায়) ──
  // সাধারণ শব্দ/বাক্যাংশ হিসেবে রাখা হয়; ইঞ্জিনের জন্য নিচে regex-এ রূপান্তর হয়।
  static const defaultInclude = <String>[
    'কম্পিউটার অপারেটর',
    'কম্পিউটার মুদ্রাক্ষরিক',
    'ডাটা এন্ট্রি',
    'ডেটা এন্ট্রি',
    'ডাটা অপারেটর',
    'ডেটা অপারেটর',
    'অফিস সহায়ক কাম',
    'computer operator',
    'data entry',
    'computer typist',
  ];
  static const defaultExclude = <String>['সাঁট', 'সীট', 'শর্টহ্যান্ড', 'stenograph', 'stenotyp', 'shorthand'];

  static List<String> _terms(String key, List<String> fallback) {
    final raw = SettingsService.getString(key);
    if (raw.isEmpty) return fallback;
    try {
      final l = (jsonDecode(raw) as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      return l.isEmpty ? fallback : l;
    } catch (_) {
      return fallback;
    }
  }

  static List<String> get includeTerms => _terms(kKwInclude, defaultInclude);
  static List<String> get excludeTerms => _terms(kKwExclude, defaultExclude);

  /// "কম্পিউটার অপারেটর" → regex (শব্দের মাঝে ফাঁক/হাইফেন যাই থাকুক মেলে)।
  static String termToPattern(String term) => term
      .trim()
      .split(RegExp(r'[\s\-–]+'))
      .where((t) => t.isNotEmpty)
      .map(RegExp.escape)
      .join(r'[\s\-–]*');

  static List<String> get keywords => includeTerms.map(termToPattern).toList();

  /// ইঞ্জিনের জন্য প্রোফাইল অবজেক্ট।
  static RadarProfile profile() {
    final p = dob.split('-').map((e) => int.tryParse(e) ?? 0).toList();
    final d = (p.length == 3 && p[0] > 0) ? DateTime.utc(p[0], p[1], p[2]) : DateTime.utc(1999, 1, 1);
    return RadarProfile(
      dob: d,
      eduRank: _eduRank[eduLevel] ?? 4,
      eduLabel: eduLevels[eduLevel] ?? eduLevel,
      subject: subject,
      typingBn: typingBn,
      typingEn: typingEn,
      targetKeywords: keywords,
      excludeKeywords: excludeTerms.map(termToPattern).toList(),
    );
  }

  // ── ক্যাশ (শেষ ফলাফল) ──
  /// ব্যাকগ্রাউন্ড টাস্ক অন্য আইসোলেটে লিখে থাকলে সেটা এখানে দেখার জন্য।
  static Future<void> reload() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
    } catch (_) {}
  }

  static RadarFeed? cached() {
    final raw = SettingsService.getString(_kCache);
    if (raw.isEmpty) return null;
    try {
      return RadarFeed.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveFeed(RadarFeed f) => SettingsService.setString(_kCache, jsonEncode(f.toMap()));

  // ── Teletalk-এর পুরো তালিকা (ব্রাউজ ভিউয়ের জন্য) ──
  static const _kTele = 'radar_teletalk_all';

  static Future<void> saveTeletalkAll(List<TeletalkJob> jobs) =>
      SettingsService.setString(_kTele, jsonEncode({'at': DateTime.now().millisecondsSinceEpoch, 'jobs': jobs.map((j) => j.toMap()).toList()}));

  static List<TeletalkJob> teletalkAll() {
    final raw = SettingsService.getString(_kTele);
    if (raw.isEmpty) return [];
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return ((m['jobs'] as List?) ?? const [])
          .map((e) => TeletalkJob.fromCache(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static DateTime? teletalkSavedAt() {
    final raw = SettingsService.getString(_kTele);
    if (raw.isEmpty) return null;
    try {
      final at = (jsonDecode(raw) as Map)['at'] as num?;
      return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at.toInt());
    } catch (_) {
      return null;
    }
  }

  // ── লুকানো (dismissed) ──
  static Set<String> dismissed() {
    final raw = SettingsService.getString(_kDismissed);
    if (raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> dismiss(String url) async {
    final list = (dismissed()..add(url)).toList();
    final keep = list.length > 300 ? list.sublist(list.length - 300) : list;
    await SettingsService.setString(_kDismissed, jsonEncode(keep));
  }

  static Future<void> restore(String url) async {
    final s = dismissed()..remove(url);
    await SettingsService.setString(_kDismissed, jsonEncode(s.toList()));
  }

  // ── রূপান্তর ──
  static const _bnDigits = '০১২৩৪৫৬৭৮৯';
  static String _toEn(String s) =>
      s.replaceAllMapped(RegExp('[০-৯]'), (m) => _bnDigits.indexOf(m[0]!).toString());

  static int _feeOf(String s) {
    final m = RegExp(r'\d+').firstMatch(_toEn(s));
    return m == null ? 0 : int.tryParse(m[0]!) ?? 0;
  }

  /// রাডারের সার্কুলার → জব হাবের Circular (নজরে)। সংরক্ষণ করবে JobService.saveCircular।
  static Circular toCircular(RadarItem it) {
    final note = StringBuffer(it.verdict == 'ok' ? 'রাডার: সম্ভাব্য যোগ্য' : 'রাডার: যাচাই বাকি');
    for (final p in it.posts) {
      for (final c in p.checks) {
        if (c.s != 'ok') note.write('\n${c.icon} ${p.title}: ${c.msg}');
      }
    }
    if (it.totalVacancy != null) note.write('\nমোট পদ: ${it.totalVacancy}টি');
    if (it.method.isNotEmpty) note.write('\nআবেদন: ${it.method}');
    note.write('\n(স্বয়ংক্রিয় যাচাই — মূল বিজ্ঞপ্তি দেখে নিশ্চিত হও)');
    return Circular(
      title: it.title,
      org: it.org,
      post: it.posts.map((p) => p.title).take(3).join(', '),
      deadline: it.deadline,
      fee: _feeOf(it.fee),
      url: it.url,
      note: note.toString(),
    );
  }

  static String ymd(DateTime d) => Reminder.ymd(d);
}

/// সেটিংস শিট থেকে একসাথে একাধিক স্ট্রিং মান সংরক্ষণ।
class SettingsPersist {
  static Future<void> save(Map<String, String> strings) async {
    for (final e in strings.entries) {
      await SettingsService.setString(e.key, e.value);
    }
  }
}
