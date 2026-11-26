import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../services/notification_service.dart';
import '../../services/settings_service.dart';
import '../models/job_models.dart';
import '../radar/engine/bdgovtjob_source.dart' show httpGet;
import 'job_service.dart';

/// "আবেদন করেছি" অবস্থার সার্কুলারের প্রবেশপত্র নজরদারি।
///
/// কীভাবে: সার্কুলারের লিংক আর নোটে থাকা আবেদন-সাইটের লিংকের পেজ পড়ে "প্রবেশপত্র / Admit Card"
/// শব্দওয়ালা লিংক ও লেখা খোঁজা হয়। প্রথম পড়ায় যা আছে সেটা "আগে থেকেই ছিল" ধরে রাখা হয়;
/// পরে নতুন কিছু এলেই নোটিফিকেশন। ফলাফল নজরদারির বাইরে (আলাদা সাইটে আসে)।
///
/// সীমা: পেজ জাভাস্ক্রিপ্টে আঁকা হলে (লিংক HTML-এ না থাকলে) ধরা যায় না; আর সাইটে আগে থেকেই
/// "প্রবেশপত্র" মেনু থাকলে সেটা নতুন নয় — শুধু নতুন নোটিশ/লিংক এলে জানায়।
class AdmitWatcher {
  static const kOn = 'admit_watch_on';
  static const _kState = 'admit_watch_state';
  static const _kLast = 'admit_watch_last';
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static bool get on => SettingsService.getString(kOn, defaultValue: '1') != '0';

  static final _admitRe = RegExp(
    r'প্রবেশ\s*পত্র|admit\s*card|admit[-_]?card|e-?admit|admission\s*card',
    caseSensitive: false,
  );

  /// ব্যাকগ্রাউন্ড isolate-এর লেখা তাজা পড়ার জন্য।
  static Future<void> reload() async {
    try {
      await (await SharedPreferences.getInstance()).reload();
    } catch (_) {}
  }

  static Map<String, dynamic> _load() {
    final raw = SettingsService.getString(_kState);
    if (raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, dynamic> m) => SettingsService.setString(_kState, jsonEncode(m));

  /// কার্ডে দেখানোর তথ্য: {found, link, label, last, err}।
  static Map<String, dynamic>? info(int? id) {
    if (id == null) return null;
    final v = _load()['$id'];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  static String lastCheckText(int? id) {
    final last = (info(id)?['last'] as num?)?.toInt();
    if (last == null) return 'এখনো চেক হয়নি';
    final mins = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)).inMinutes;
    if (mins < 2) return 'এইমাত্র চেক হয়েছে';
    if (mins < 60) return '${bn(mins)} মিনিট আগে চেক হয়েছে';
    if (mins < 60 * 24) return '${bn(mins ~/ 60)} ঘণ্টা আগে চেক হয়েছে';
    return '${bn(mins ~/ (60 * 24))} দিন আগে চেক হয়েছে';
  }

  // ── পেজ থেকে প্রবেশপত্রের চিহ্ন বের করা ──

  static List<String> _urlsFor(Circular c) {
    final out = <String>[];
    void add(String raw) {
      var u = raw.trim().replaceAll(RegExp(r'[)\].,;]+$'), '');
      final h = u.indexOf('#');
      if (h >= 0) u = u.substring(0, h);
      if (!u.startsWith('http')) return;
      if (u.toLowerCase().endsWith('.pdf')) return;
      if (!out.contains(u)) out.add(u);
    }

    if (c.url.isNotEmpty) add(c.url);
    for (final m in RegExp(r'https?://[^\s<>"]+').allMatches(c.note)) {
      add(m.group(0)!);
    }
    return out.take(3).toList();
  }

  static String _strip(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'&nbsp;|&#160;'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// sig -> (label, link)
  static Map<String, ({String label, String link})> _signalsIn(String html, String base) {
    final out = <String, ({String label, String link})>{};
    final anchors = RegExp(r'''<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>''', caseSensitive: false, dotAll: true);
    for (final m in anchors.allMatches(html)) {
      final href = (m.group(1) ?? '').trim();
      final text = _strip(m.group(2) ?? '');
      if (!_admitRe.hasMatch(text) && !_admitRe.hasMatch(href)) continue;
      var link = href;
      try {
        link = Uri.parse(base).resolve(href).toString();
      } catch (_) {}
      final label = text.isEmpty ? 'প্রবেশপত্র লিংক' : (text.length > 90 ? text.substring(0, 90) : text);
      out['a|${text.toLowerCase()}|$link'] = (label: label, link: link);
    }
    // লিংকের বাইরে সাধারণ লেখায় (যেমন "প্রবেশপত্র প্রকাশিত হয়েছে")
    final body = _strip(html.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), ' '));
    var n = 0;
    for (final m in _admitRe.allMatches(body)) {
      if (n++ >= 6) break;
      final s = (m.start - 45).clamp(0, body.length);
      final e = (m.end + 60).clamp(0, body.length);
      final snippet = body.substring(s, e).trim();
      out['t|${snippet.toLowerCase()}'] = (label: snippet, link: base);
    }
    return out;
  }

  /// ফলাফল: baseline (প্রথমবার, নজরদারি শুরু) | found (নতুন কিছু পাওয়া গেছে) | none | error
  static Future<({String status, String label, String link})> check(Circular c, {bool notify = true}) async {
    final id = c.id;
    if (id == null) return (status: 'error', label: '', link: '');
    final urls = _urlsFor(c);
    final signals = <String, ({String label, String link})>{};
    var okAny = false;
    String? err;
    for (final u in urls) {
      try {
        signals.addAll(_signalsIn(await httpGet(u), u));
        okAny = true;
      } catch (e) {
        err = e.toString().replaceFirst('Exception: ', '');
      }
    }

    final all = _load();
    final prev = all['$id'] is Map ? Map<String, dynamic>.from(all['$id'] as Map) : <String, dynamic>{};
    final entry = Map<String, dynamic>.from(prev);
    entry['last'] = DateTime.now().millisecondsSinceEpoch;
    entry['err'] = okAny ? '' : (err ?? (urls.isEmpty ? 'চেক করার মতো লিংক নেই — সার্কুলারে লিংক দাও' : 'পেজ খোলা যায়নি'));

    var status = 'none';
    var label = '';
    var link = '';
    if (!okAny) {
      status = 'error';
    } else if (prev['base'] != true) {
      entry['base'] = true;
      entry['sig'] = signals.keys.toList();
      status = 'baseline';
    } else {
      final seen = ((prev['sig'] as List?) ?? const []).map((e) => e.toString()).toSet();
      final fresh = signals.entries.where((e) => !seen.contains(e.key)).toList();
      // লিংকওয়ালা (a|) আগে — সেটাই ডাউনলোডের পথ
      fresh.sort((a, b) => (b.key.startsWith('a|') ? 1 : 0).compareTo(a.key.startsWith('a|') ? 1 : 0));
      entry['sig'] = {...seen, ...signals.keys}.toList();
      if (fresh.isNotEmpty) {
        status = 'found';
        label = fresh.first.value.label;
        link = fresh.first.value.link;
        entry['found'] = true;
        entry['foundAt'] = DateTime.now().millisecondsSinceEpoch;
        entry['label'] = label;
        entry['link'] = link;
        if (notify) {
          final name = c.org.isNotEmpty ? c.org : c.title;
          await NotificationService.showAdmitFound(
            id,
            '🎫 প্রবেশপত্র এসেছে মনে হচ্ছে: $name',
            label,
            '$name${c.post.isNotEmpty ? ' (${c.post})' : ''}\n\n'
            'সাইটে নতুন পাওয়া: $label\n$link\n\n'
            'অ্যাপের চাকরি-হাবে সার্কুলারের কার্ডে "🎫 প্রবেশপত্র" চেপে লিংক খোলো, তারপর অবস্থা "প্রবেশপত্র পেয়েছি" করে দাও।',
          );
        }
      }
    }
    all['$id'] = entry;
    await _save(all);
    changes.value++;
    return (status: status, label: label, link: link);
  }

  /// "আবেদন করেছি" অবস্থার সব সার্কুলার ~৩ ঘণ্টায় একবার চেক। [force] হলে সময়ের শর্ত ছাড়াই।
  /// ফেরত: (কয়টা চেক হলো, কয়টায় নতুন প্রবেশপত্র পাওয়া গেল)।
  static Future<({int checked, int found})> checkAllIfDue({bool force = false}) async {
    if (!on) return (checked: 0, found: 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - SettingsService.getInt(_kLast) < 3 * 3600 * 1000) return (checked: 0, found: 0);
    final list = (await JobService.circulars()).where((c) {
      if (c.status != 'applied') return false;
      // আবেদন শেষের ১৫০ দিন পরও প্রবেশপত্র না এলে আর খুঁজি না
      if (c.deadline != null && DateTime.now().difference(c.deadline!).inDays > 150) return false;
      return true;
    }).take(8).toList();
    var checked = 0;
    var found = 0;
    for (final c in list) {
      try {
        final r = await check(c);
        checked++;
        if (r.status == 'found') found++;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    await SettingsService.setInt(_kLast, now);
    return (checked: checked, found: found);
  }

  /// অবস্থা "আবেদন করেছি" থেকে সরলে নজরদারির তথ্য মুছে ফেলা।
  static Future<void> forget(int? id) async {
    if (id == null) return;
    final all = _load();
    if (all.remove('$id') != null) {
      await _save(all);
      changes.value++;
    }
  }
}
