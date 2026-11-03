import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/settings_service.dart';
import '../radar/engine/teletalk_source.dart';

/// 📌 বড় নিয়োগ: অনেক পদে লোক নেওয়া হচ্ছে (যেমন শিক্ষক নিয়োগ, সমাজসেবা…) এমন সার্কুলার সামনে আনার নিয়ম।
/// দুটো উপায়ে "বড়" ধরা হয় — (১) পদসংখ্যা [threshold]-এর সমান/বেশি; (২) প্রতিষ্ঠান/পদের নামে ব্যবহারকারীর দেওয়া শব্দ।
/// শব্দ কোডে বাঁধা নেই — জব প্রোফাইল থেকে যোগ-বদল; সীমাও বদলানো যায় (শুরুতে ১০০)।
class BigHiring {
  static const _kThreshold = 'big_hiring_threshold';
  static const _kWords = 'big_hiring_words';
  static const defaultThreshold = 100;
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static int get threshold {
    final v = SettingsService.getInt(_kThreshold, defaultValue: defaultThreshold);
    return v < 1 ? defaultThreshold : v;
  }

  static Future<void> setThreshold(int v) async {
    await SettingsService.setInt(_kThreshold, v < 1 ? defaultThreshold : v);
    changes.value++;
  }

  static List<String> get words {
    final s = SettingsService.getString(_kWords);
    if (s.isEmpty) return const [];
    try {
      return (jsonDecode(s) as List).map((e) => e.toString().trim()).where((e) => e.length >= 2).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> setWords(List<String> w) async {
    await SettingsService.setString(_kWords, jsonEncode(w.map((e) => e.trim()).where((e) => e.length >= 2).toList()));
    changes.value++;
  }

  /// এই চাকরিটা "বড় নিয়োগ" কি না, আর কেন (পদসংখ্যা/শব্দ) — কার্ডে কারণসহ দেখানোর জন্য।
  static ({bool big, String? why}) classify(TeletalkJob j, {int? thr, List<String>? ws}) {
    final t = thr ?? threshold;
    final v = j.vacancy;
    if (v != null && v >= t) return (big: true, why: 'পদ $v');
    final hay = '${j.titleBn} ${j.titleEn} ${j.orgName} ${j.orgNameBn} ${j.shortName}'.toLowerCase();
    for (final w in (ws ?? words)) {
      if (hay.contains(w.toLowerCase())) return (big: true, why: w);
    }
    return (big: false, why: null);
  }
}
