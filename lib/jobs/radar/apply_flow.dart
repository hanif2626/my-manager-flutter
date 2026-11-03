import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../reminder/models/reminder.dart' show bn;
import '../../services/settings_service.dart';
import '../../widgets/app_theme.dart';
import '../services/app_launcher.dart';
import '../models/job_models.dart';
import '../services/job_service.dart';
import 'engine/bn_util.dart' show fmtDateBn;
import 'radar_models.dart';
import 'radar_pdf_viewer.dart';
import 'radar_service.dart';

/// "আবেদন করো" — সাবধানে: খোলার আগে সাইটের ঠিকানা (অফিসিয়াল কি না) ও শেষ তারিখ দেখায়, মেয়াদ-শেষে আটকায়,
/// আর ফর্ম খুলে ফিরে এলে জিজ্ঞেস করে "আবেদন সম্পন্ন হয়েছে?" — হ্যাঁ বললেই কেবল "আবেদন করেছি" চিহ্নিত হয়
/// (নিজে থেকে কখনো ধরে নেয় না)।
class ApplyFlow {
  static const _kPending = 'radar_pending_apply';

  /// আবেদনের ঠিকানা: স্পষ্ট ঠিকানা থাকলে সেটা, নইলে "আবেদন পদ্ধতি"র লেখা থেকে প্রথম লিংক।
  static String bestUrl(RadarItem it) {
    if (it.applyUrl.trim().startsWith('http')) return it.applyUrl.trim();
    final m = RegExp(r'https?://[^\s,;)<>"]+').firstMatch(it.method);
    return m?.group(0) ?? '';
  }

  static String host(String url) => Uri.tryParse(url)?.host ?? '';

  /// সাইটের ধরন চিনিয়ে দেয় — ভুয়া/অচেনা সাইটে তথ্য দিয়ে ফেলা ঠেকাতে।
  static ({String label, Color color, bool official}) siteInfo(String url) {
    final h = host(url).toLowerCase();
    if (h == 'teletalk.com.bd' || h.endsWith('.teletalk.com.bd')) {
      return (label: '✅ Teletalk-এর অফিসিয়াল ঠিকানা', color: AppTheme.green, official: true);
    }
    if (h.endsWith('.gov.bd')) {
      return (label: '🏛️ সরকারি (gov.bd) ঠিকানা', color: AppTheme.green, official: true);
    }
    return (label: '⚠️ অচেনা সাইট — ঠিকানা বিজ্ঞপ্তির সাথে মিলিয়ে নাও', color: AppTheme.yellow, official: false);
  }

  // ── সরাসরি আবেদন-ফর্মের লিংক ──
  //
  // Teletalk-এর প্রতিটা প্রতিষ্ঠানের সাইট প্রথমে একটা "মাঝের পাতা" দেখায় (বিজ্ঞপ্তি ডাউনলোড + "Application Form
  // (Click here to Apply Online)" লিংক); আসল আবেদন শুরু হয় তার পরের পাতায়। সেই পাতার লিংক খুঁজে সরাসরি সেখানে নিয়ে যাই।
  // নিরাপত্তা: পাওয়া লিংক Teletalk/gov.bd বা একই সাইটের না হলে নিই না; আর না পেলে মাঝের পাতাই খুলি।

  static final Map<String, ({String? apply, String? ad})> _directCache = {};

  static Future<({String? apply, String? ad})> resolveDirect(String landing) async {
    final hit = _directCache[landing];
    if (hit != null) return hit;
    final r = await _resolve(landing);
    if (r.apply != null || r.ad != null) _directCache[landing] = r;
    return r;
  }

  static bool _trusted(Uri link, Uri base) {
    final h = link.host.toLowerCase();
    if (h == base.host.toLowerCase()) return true;
    return h == 'teletalk.com.bd' || h.endsWith('.teletalk.com.bd') || h.endsWith('.gov.bd');
  }

  static Future<({String? apply, String? ad})> _resolve(String landing) async {
    final u = Uri.tryParse(landing);
    if (u == null || u.host.isEmpty) return (apply: null, ad: null);
    // http সাইট আগে https-এ চেষ্টা (অ্যান্ড্রয়েড সাধারণ http অনুরোধ আটকায়), না হলে যেমন আছে
    final tries = <Uri>[if (u.scheme == 'http') u.replace(scheme: 'https'), u];
    for (final t in tries) {
      try {
        final res = await http.get(t, headers: {
          'user-agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
          'accept': 'text/html,*/*',
          'accept-language': 'en,bn;q=0.8',
        }).timeout(const Duration(seconds: 7));
        if (res.statusCode != 200) continue;
        return _parseLinks(utf8.decode(res.bodyBytes, allowMalformed: true), t);
      } catch (_) {}
    }
    return (apply: null, ad: null);
  }

  static ({String? apply, String? ad}) _parseLinks(String html, Uri base) {
    final anchors = RegExp(r'''<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>''', caseSensitive: false, dotAll: true);
    final applyRe = RegExp(r'application\s*form|apply\s*online', caseSensitive: false);
    final adRe = RegExp(r'advertisement|download\s*circular', caseSensitive: false);
    String? apply;
    String? ad;
    for (final m in anchors.allMatches(html)) {
      final href = (m.group(1) ?? '').trim();
      if (href.isEmpty || href.startsWith('#') || href.toLowerCase().startsWith('javascript:')) continue;
      final text = (m.group(2) ?? '').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      Uri? link;
      try {
        link = base.resolve(href);
      } catch (_) {}
      if (link == null || !(link.scheme == 'http' || link.scheme == 'https') || !_trusted(link, base)) continue;
      if (apply == null && applyRe.hasMatch(text)) apply = link.toString();
      if (ad == null && adRe.hasMatch(text)) ad = link.toString();
    }
    return (apply: apply, ad: ad);
  }

  /// আবেদনের আগের নিশ্চিতকরণ-শিট; "ফর্ম খোলো" চাপলে ফর্ম খোলে আর ফিরে এলে জিজ্ঞেস করার জন্য মনে রাখে।
  static Future<void> open(BuildContext context, RadarItem it) async {
    final url = bestUrl(it);
    final dl = it.daysLeft;
    final expired = dl != null && dl < 0;
    final direct = url.isEmpty ? Future.value((apply: null as String?, ad: null as String?)) : resolveDirect(url);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('আবেদন করার আগে দেখে নাও',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(it.org.isNotEmpty ? it.org : it.title,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700, height: 1.3)),
            const SizedBox(height: 10),
            // শেষ তারিখ
            _line(
              expired ? '⛔' : (dl != null && dl <= 3 ? '🔥' : '📅'),
              it.deadline == null
                  ? 'শেষ তারিখ জানা নেই — বিজ্ঞপ্তি দেখো'
                  : 'শেষ তারিখ ${fmtDateBn(it.deadline!)}'
                      '${expired ? ' — মেয়াদ শেষ, আবেদন করা যাবে না' : (dl == 0 ? ' — আজই শেষ দিন!' : ' — আর ${bn(dl!)} দিন')}',
              expired ? AppTheme.red : (dl != null && dl <= 3 ? AppTheme.red : AppTheme.textSecondary),
            ),
            if (it.notStartedYet)
              _line('⏰', 'আবেদন শুরু ${fmtDateBn(it.published!)} — এখনো শুরু হয়নি, ফর্ম খুললেও জমা নিতে না-ও পারে', AppTheme.yellow),
            if (it.fee.isNotEmpty) _line('💰', 'ফি: ${it.fee}', AppTheme.textSecondary),
            const SizedBox(height: 10),
            FutureBuilder<({String? apply, String? ad})>(
              future: direct,
              builder: (ctx, snap) {
                final resolving = url.isNotEmpty && snap.connectionState != ConnectionState.done;
                final found = snap.data?.apply;
                final target = found ?? url;
                final info = siteInfo(target);
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.bg.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: info.color.withOpacity(0.5)),
                    ),
                    child: url.isEmpty
                        ? Text('⚠️ এই সার্কুলারে আবেদনের লিংক পাওয়া যায়নি। "বিজ্ঞপ্তি PDF" দেখে আবেদনের ঠিকানা মিলিয়ে নাও।',
                            style: TextStyle(color: AppTheme.yellow, fontSize: 13, height: 1.4))
                        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(found != null ? 'আবেদন ফর্ম (সরাসরি)' : 'আবেদনের সাইট',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
                            const SizedBox(height: 2),
                            SelectableText(host(target), style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(info.label, style: TextStyle(color: info.color, fontSize: 12.5, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            if (resolving)
                              Row(children: [
                                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('সরাসরি আবেদন ফর্মের লিংক খোঁজা হচ্ছে…',
                                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                                ),
                              ])
                            else if (found != null)
                              Text('✅ মাঝের পাতা বাদ দিয়ে সরাসরি আবেদন ফর্মে যাবে।',
                                  style: TextStyle(color: AppTheme.green, fontSize: 12, height: 1.4))
                            else
                              Text('সরাসরি ফর্মের লিংক পাওয়া যায়নি — সাইট খুলে "Application Form (Click here to Apply Online)" লিংকে চাপো।',
                                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
                            const SizedBox(height: 4),
                            Text('শুধু এই ঠিকানাতেই তথ্য দাও। বিজ্ঞপ্তির ঠিকানার সাথে না মিললে খুলো না।',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
                          ]),
                  ),
                  const SizedBox(height: 10),
                  Text('হাতের কাছে রাখো: ছবি ও স্বাক্ষর (মাপ অনুযায়ী) · জাতীয় পরিচয়পত্র/জন্মনিবন্ধন · সব শিক্ষাগত সনদ ও নম্বরপত্র · ফি দেওয়ার মোবাইল ব্যাংকিং',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.45)),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: (expired || url.isEmpty || resolving)
                          ? null
                          : () async {
                              await _setPending(it);
                              final ok = await AppLauncher.openUrl(target);
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (!ok && context.mounted) {
                                await clearPending();
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('লিংক খোলা যায়নি')));
                              }
                            },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: Text(expired ? 'মেয়াদ শেষ' : (found != null ? 'আবেদন ফর্ম খোলো' : 'আবেদনের সাইট খোলো')),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () {
                        final ad = snap.data?.ad;
                        Navigator.pop(ctx);
                        openRadarPdf(context,
                            title: it.org.isNotEmpty ? it.org : it.title, adFile: it.adFile, pageUrl: it.url, directUrl: ad);
                      },
                      icon: Icon(Icons.picture_as_pdf_rounded, color: AppTheme.red),
                      label: const Text('আগে বিজ্ঞপ্তি PDF দেখো'),
                    ),
                  ),
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }

  static Widget _line(String emoji, String text, Color c) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$emoji ', style: const TextStyle(fontSize: 14)),
          Expanded(child: Text(text, style: TextStyle(color: c, fontSize: 13, height: 1.35, fontWeight: FontWeight.w600))),
        ]),
      );

  // ── ফর্ম খুলে ফিরে এলে জিজ্ঞেস ──

  static Future<void> _setPending(RadarItem it) =>
      SettingsService.setString(_kPending, jsonEncode({'item': it.toMap(), 'at': DateTime.now().millisecondsSinceEpoch}));

  static Future<void> clearPending() => SettingsService.setString(_kPending, '');

  static RadarItem? pending() {
    final s = SettingsService.getString(_kPending);
    if (s.isEmpty) return null;
    try {
      final m = Map<String, dynamic>.from(jsonDecode(s) as Map);
      final at = (m['at'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - at > 24 * 3600 * 1000) return null; // ২৪ ঘণ্টা পর আর জিজ্ঞেস নয়
      return RadarItem.fromMap(Map<String, dynamic>.from(m['item'] as Map));
    } catch (_) {
      return null;
    }
  }

  static bool _asking = false;

  /// আবেদনের ফর্ম খোলা ছিল এমন সার্কুলার থাকলে জিজ্ঞেস: আবেদন সম্পন্ন হয়েছে? হ্যাঁ → "আবেদন করেছি" চিহ্নিত।
  static Future<void> askIfPending(BuildContext context, VoidCallback onChanged) async {
    if (_asking) return;
    final it = pending();
    if (it == null) return;
    _asking = true;
    try {
      final name = it.org.isNotEmpty ? it.org : it.title;
      final r = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bg2,
          title: const Text('আবেদন সম্পন্ন করেছো?'),
          content: Text(
            '"$name"-এর আবেদন-সাইট খুলেছিলে। আবেদন জমা দেওয়া হয়ে গেলে "হ্যাঁ" চাপো — সার্কুলারটা "আবেদন করেছি" চিহ্নিত হবে '
            '(ফি থাকলে ক্যাশবুকে খরচ লেখা হবে, প্রবেশপত্র নজরদারিও শুরু হবে)।\n\nজমা না দিয়ে থাকলে "এখনো না" চাপো।',
            style: const TextStyle(height: 1.45),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 0), child: const Text('না, আবেদন করিনি')),
            TextButton(onPressed: () => Navigator.pop(ctx, 1), child: const Text('পরে জিজ্ঞেস করো')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 2),
              child: Text('হ্যাঁ, করেছি', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        ),
      );
      if (r == 1 || r == null) return; // পরে আবার জিজ্ঞেস করবে
      await clearPending();
      if (r != 2) return;
      final list = await JobService.circulars();
      Circular? c;
      for (final x in list) {
        if (x.url == it.url) {
          c = x;
          break;
        }
      }
      if (c == null) {
        c = RadarService.toCircular(it);
        await JobService.saveCircular(c);
      }
      final msg = await JobService.setStatus(c, 'applied');
      onChanged();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg ?? '✔ "আবেদন করেছি" চিহ্নিত হয়েছে')));
      }
    } finally {
      _asking = false;
    }
  }
}
