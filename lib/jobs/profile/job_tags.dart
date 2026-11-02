import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/settings_service.dart';
import '../radar/radar_models.dart';

/// ব্যবহারকারীর নিজের ট্যাগ (যেমন কোনো বাহিনীর সদস্য, কম্পিউটার দক্ষতা…) — কোডে বাঁধা কিছু নেই; প্রোফাইল থেকে যোগ-বদল।
/// ট্যাগের নাম ও "মিলানোর শব্দ"গুলোর কোনোটা সার্কুলারের প্রতিষ্ঠান/পদের নামে থাকলে ট্যাগটা ওই সার্কুলারে মেলে।
class JobTag {
  final String name;
  final List<String> words; // বাড়তি মিলানোর শব্দ (খালি হলে শুধু নামটাই)
  const JobTag(this.name, [this.words = const []]);

  Map<String, dynamic> toMap() => {'n': name, 'w': words};
  factory JobTag.fromMap(Map<String, dynamic> m) => JobTag(
        (m['n'] ?? '').toString(),
        ((m['w'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );

  /// মেলানোর সব শব্দ: নাম + বাড়তিগুলো (ছোট হাতের, ফাঁকা বাদে, ২ অক্ষরের কম বাদে)।
  List<String> get needles {
    final out = <String>{};
    for (final w in [name, ...words]) {
      final t = w.trim().toLowerCase();
      if (t.length >= 2) out.add(t);
    }
    return out.toList();
  }
}

class JobTags {
  static const key = 'job_tags';
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static List<JobTag> all() {
    final s = SettingsService.getString(key);
    if (s.isEmpty) return const [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => JobTag.fromMap(Map<String, dynamic>.from(e as Map)))
          .where((t) => t.name.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveAll(List<JobTag> list) async {
    await SettingsService.setString(key, jsonEncode(list.map((e) => e.toMap()).toList()));
    changes.value++;
  }

  static String _hay(RadarItem it) => [
        it.org,
        it.title,
        for (final p in it.posts) p.title,
        it.method,
        it.adNo,
      ].join(' ').toLowerCase();

  /// এই সার্কুলারে যে ট্যাগগুলো মেলে তাদের নাম। [tags] দিলে বারবার ডিস্ক পড়া লাগে না।
  static List<String> match(RadarItem it, {List<JobTag>? tags}) {
    final list = tags ?? all();
    if (list.isEmpty) return const [];
    final hay = _hay(it);
    final out = <String>[];
    for (final t in list) {
      if (t.needles.any(hay.contains)) out.add(t.name);
    }
    return out;
  }
}
