import 'dart:convert';
import 'package:flutter/services.dart';
import '../reminder/models/reminder.dart';
import '../services/settings_service.dart';

/// অ্যাপের ধরন → (ইমোজি, নাম)
const stCats = <String, (String, String)>{
  'study': ('📚', 'পড়াশোনা'),
  'work': ('🛠️', 'কাজের'),
  'social': ('💬', 'সোশ্যাল'),
  'video': ('🎬', 'ভিডিও'),
  'game': ('🎮', 'গেম'),
  'browser': ('🌐', 'ব্রাউজার'),
  'other': ('⚪', 'অন্যান্য'),
  'ignore': ('🚫', 'হিসাবের বাইরে'),
};

enum StGroup { study, waste, neutral, ignore }

StGroup groupOf(String cat) {
  switch (cat) {
    case 'study': return StGroup.study;
    case 'social':
    case 'video':
    case 'game': return StGroup.waste;
    case 'ignore': return StGroup.ignore;
    default: return StGroup.neutral;
  }
}

class AppUse {
  final String pkg;
  final String label;
  final int ms;
  String cat;
  AppUse(this.pkg, this.label, this.ms, this.cat);
  StGroup get group => groupOf(cat);
}

class DayTotals {
  final DateTime day;
  final int studyMs; // অ্যাপ + হাতে যোগ করা
  final int manualMs;
  final int wasteMs;
  final int neutralMs;
  final List<AppUse> apps;
  DayTotals(this.day, this.studyMs, this.manualMs, this.wasteMs, this.neutralMs, this.apps);
  int get totalMs => studyMs - manualMs + wasteMs + neutralMs; // ফোনের আসল স্ক্রিন টাইম
}

String fmtMs(int ms) {
  final m = ms ~/ 60000;
  final h = m ~/ 60;
  final r = m % 60;
  if (h > 0 && r > 0) return '${bn(h)}ঘ ${bn(r)}মি';
  if (h > 0) return '${bn(h)} ঘণ্টা';
  return '${bn(m)} মিনিট';
}

/// স্ক্রিন টাইম: কোন অ্যাপে কত সময়, পড়া বনাম অপচয়, লক্ষ্য ও সতর্কবার্তার কনফিগ।
class ScreenTimeService {
  static const _ch = MethodChannel('com.hanif.mymanager/screentime');
  static const _kOverrides = 'st_overrides';
  static const _kStudyGoal = 'st_study_goal_min';
  static const _kWasteLimit = 'st_waste_limit_min';
  static const _kNudge = 'st_nudge_on';
  static const _kManual = 'st_manual'; // {"yyyy-MM-dd": মিনিট}

  // ───────────── অনুমতি ─────────────

  static Future<bool> hasAccess() async {
    try {
      return (await _ch.invokeMethod<bool>('hasAccess')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAccessSettings() async {
    try {
      await _ch.invokeMethod('openAccessSettings');
    } catch (_) {}
  }

  // ───────────── লক্ষ্য ও সেটিংস ─────────────

  static int get studyGoalMin => SettingsService.getInt(_kStudyGoal, defaultValue: 180);
  static int get wasteLimitMin => SettingsService.getInt(_kWasteLimit, defaultValue: 120);
  static bool get nudgeOn => SettingsService.getBool(_kNudge, defaultValue: true);

  static Future<void> saveGoals({required int studyMin, required int wasteMin, required bool nudge}) async {
    await SettingsService.setInt(_kStudyGoal, studyMin);
    await SettingsService.setInt(_kWasteLimit, wasteMin);
    await SettingsService.setBool(_kNudge, nudge);
    await syncConfig();
  }

  // ───────────── হাতে পড়ার সময় (বই/খাতা) ─────────────

  static String dayKey(DateTime d) => Reminder.ymd(d);

  static Map<String, dynamic> _manualMap() {
    try {
      return jsonDecode(SettingsService.getString(_kManual)) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static int manualMinutes(DateTime day) => (_manualMap()[dayKey(day)] as int?) ?? 0;

  static Future<void> addManualMinutes(DateTime day, int min) async {
    final m = _manualMap();
    m[dayKey(day)] = ((m[dayKey(day)] as int?) ?? 0) + min;
    // শুধু শেষ ৯০ দিনের হিসাব রাখি
    final cutoff = dayKey(DateTime.now().subtract(const Duration(days: 90)));
    m.removeWhere((k, _) => k.compareTo(cutoff) < 0);
    await SettingsService.setString(_kManual, jsonEncode(m));
    await syncConfig();
  }

  // ───────────── ধরন (ক্যাটাগরি) ─────────────

  static Map<String, String> _overrides() {
    try {
      return Map<String, String>.from(jsonDecode(SettingsService.getString(_kOverrides)) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> setCategory(String pkg, String cat) async {
    final o = _overrides()..[pkg] = cat;
    await SettingsService.setString(_kOverrides, jsonEncode(o));
    await syncConfig();
  }

  static bool _has(String pkg, List<String> parts) => parts.any((p) => pkg.contains(p));

  /// ডিফল্ট ধরন (আন্দাজ) — ব্যবহারকারী যেকোনো অ্যাপে ট্যাপ করে বদলাতে পারে।
  static String defaultCategory(String pkg) {
    final p = pkg.toLowerCase();
    if (_has(p, ['smartstudy', 'com.adobe.reader', 'org.readera', 'amazon.kindle', 'apps.classroom',
        'khanacademy', 'ichi2.anki', 'duolingo', 'quizlet', 'cn.wps.moffice', 'xodo', 'udemy',
        'coursera', 'edx', 'apps.books', 'moon.android', 'flutter_pdf', 'pdfviewer', 'pdfreader',
        'shobdokosh', 'bdjobs', 'bcs', 'ebook', 'bookreader'])) {
      return 'study';
    }
    if (_has(p, ['com.facebook.', 'instagram', 'twitter', 'com.snapchat', 'musically', 'ugc.trill',
        'whatsapp', 'telegram', 'imo.android', 'viber', 'linkedin', 'pinterest', 'reddit',
        'discord', 'barcelona', 'threads', 'tinder', 'likee', 'kwai'])) {
      return 'social';
    }
    if (_has(p, ['youtube', 'netflix', 'bongo', 'chorki', 'hoichoi', 'mxtech', 'videolan',
        'twitch', 'hotstar', 'primevideo', 'vimeo', 'dailymotion', 'toffee'])) {
      return 'video';
    }
    if (_has(p, ['.game', 'games', 'supercell', 'com.king.', 'tencent.ig', 'freefire', 'garena',
        'activision', 'mojang', 'roblox', 'ludo', 'miniclip', 'innersloth', 'pubg', 'candy', 'carrom'])) {
      return 'game';
    }
    if (_has(p, ['com.android.chrome', 'org.mozilla', 'com.brave', 'opera', 'microsoft.emmx',
        'sec.android.app.sbrowser', 'duckduckgo', 'vivaldi', 'kiwibrowser', 'browser'])) {
      return 'browser';
    }
    if (_has(p, ['com.hanif.mymanager', 'apps.docs', 'google.android.keep', 'google.android.gm',
        'apps.tasks', 'calendar', 'microsoft.office', 'google.android.apps.maps'])) {
      return 'work';
    }
    if (_has(p, ['com.android.settings', 'inputmethod', 'launcher', 'systemui', 'permissioncontroller'])) {
      return 'ignore';
    }
    return 'other';
  }

  static String categoryOf(String pkg) => _overrides()[pkg] ?? defaultCategory(pkg);

  // ───────────── ব্যবহারের হিসাব ─────────────

  static Future<List<AppUse>> usage(DateTime start, DateTime end) async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('usage', {
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
      });
      final o = _overrides();
      final out = <AppUse>[];
      for (final e in raw ?? const []) {
        try {
          final m = Map<String, dynamic>.from(e as Map);
          final pkg = (m['package'] ?? '').toString();
          if (pkg.isEmpty) continue;
          out.add(AppUse(
              pkg,
              (m['label'] ?? pkg).toString(),
              (m['ms'] as num?)?.toInt() ?? 0,
              o[pkg] ?? defaultCategory(pkg)));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// [day] দিনের মোট: ২৪ ঘণ্টা (আজ হলে এখন পর্যন্ত)।
  static Future<DayTotals> day(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    var end = start.add(const Duration(days: 1));
    final now = DateTime.now();
    if (end.isAfter(now)) end = now;
    final apps = await usage(start, end);

    int study = 0, waste = 0, neutral = 0;
    for (final a in apps) {
      switch (a.group) {
        case StGroup.study: study += a.ms; break;
        case StGroup.waste: waste += a.ms; break;
        case StGroup.neutral: neutral += a.ms; break;
        case StGroup.ignore: break;
      }
    }
    final manual = manualMinutes(day) * 60000;
    return DayTotals(start, study + manual, manual, waste, neutral, apps);
  }

  // ───────────── নেটিভ ব্যাকগ্রাউন্ড চেকের কনফিগ ─────────────

  /// গত ৭ দিনে দেখা অ্যাপগুলোর তালিকা বানিয়ে নেটিভ ওয়ার্কারকে দেয়। নতুন ইনস্টল
  /// করা অ্যাপ অ্যাপ খোলার পর পরের সিঙ্ক থেকে ধরা পড়ে।
  static Future<void> syncConfig() async {
    try {
      final now = DateTime.now();
      final apps = await usage(now.subtract(const Duration(days: 7)), now);
      final study = <String>[], waste = <String>[];
      for (final a in apps) {
        if (a.group == StGroup.study) study.add(a.pkg);
        if (a.group == StGroup.waste) waste.add(a.pkg);
      }
      // ওভাররাইড করা কিন্তু গত ৭ দিনে দেখা যায়নি এমনগুলোও
      _overrides().forEach((pkg, cat) {
        final g = groupOf(cat);
        if (g == StGroup.study && !study.contains(pkg)) study.add(pkg);
        if (g == StGroup.waste && !waste.contains(pkg)) waste.add(pkg);
      });
      final cfg = {
        'enabled': nudgeOn,
        'limitMin': wasteLimitMin,
        'studyGoalMin': studyGoalMin,
        'study': study,
        'waste': waste,
        'manual': {'day': dayKey(now), 'min': manualMinutes(now)},
      };
      await _ch.invokeMethod('saveConfig', {'json': jsonEncode(cfg)});
    } catch (_) {}
  }

  // ───────────── Digital Wellbeing সহায়ক ─────────────

  /// 'wellbeing' = Digital Wellbeing খুলেছে, 'settings' = পায়নি, সাধারণ সেটিংস খুলেছে
  static Future<String> openWellbeing() async {
    try {
      return (await _ch.invokeMethod<String>('openWellbeing')) ?? 'settings';
    } catch (_) {
      return 'settings';
    }
  }

  static Future<void> openAppNotifications(String pkg) async {
    try {
      await _ch.invokeMethod('openAppNotifications', {'package': pkg});
    } catch (_) {}
  }

  static Future<void> openAppDetails(String pkg) async {
    try {
      await _ch.invokeMethod('openAppDetails', {'package': pkg});
    } catch (_) {}
  }
}
