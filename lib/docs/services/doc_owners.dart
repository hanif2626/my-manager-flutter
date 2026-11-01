import 'dart:convert';
import '../../services/settings_service.dart';
import '../models/doc_models.dart';

/// ডকুমেন্ট ভল্টে "কার ডকুমেন্ট" — নামের তালিকা ও এখন কোন নামটা বাছা আছে।
/// প্রথমবার ঢুকলে নাম বাছতে হয়; পরে অ্যাপ বারের ড্রপডাউন থেকে বদলানো যায়। যার নাম, শুধু তারই ডকুমেন্ট দেখায়।
class DocOwners {
  /// শুরুর নাম (বদলানো/বাড়ানো যায়)। তালিকার প্রথম নামটাই "নিজের" — আগে মালিক ফাঁকা থাকা ডকুমেন্ট এই নামে ধরা হয়।
  static const defaults = ['হানিফ সরদার', 'সোয়াদ সরদার', 'শিরিন আক্তার'];

  /// ড্রপডাউনে "সবার ডকুমেন্ট" বোঝাতে বিশেষ মান।
  static const all = '*';

  static const _kList = 'docs_owners';
  static const _kSel = 'docs_owner_sel';

  static List<String> saved() {
    final raw = SettingsService.getString(_kList);
    if (raw.isNotEmpty) {
      try {
        final l = (jsonDecode(raw) as List).map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        if (l.isNotEmpty) return l;
      } catch (_) {}
    }
    return [...defaults];
  }

  static String get self => saved().first;

  /// null → এখনো কাউকে বাছা হয়নি (প্রথমবার)।
  static String? selected() {
    final s = SettingsService.getString(_kSel);
    return s.isEmpty ? null : s;
  }

  static Future<void> select(String name) => SettingsService.setString(_kSel, name);

  static Future<void> add(String name) async {
    final n = name.trim();
    if (n.isEmpty || n == all) return;
    final l = saved();
    if (!l.any((e) => e.toLowerCase() == n.toLowerCase())) {
      l.add(n);
      await SettingsService.setString(_kList, jsonEncode(l));
    }
  }

  /// ডকুমেন্টটা কার — মালিক ফাঁকা (পুরনো ডকুমেন্ট) হলে "নিজের" নাম।
  static String keyOf(VaultDoc d) {
    final o = d.owner.trim();
    return o.isEmpty ? self : o;
  }

  /// সংরক্ষিত নাম + ডকুমেন্টে থাকা নাম — যাতে কোনো ডকুমেন্টের মালিক তালিকার বাইরে পড়ে না থাকে।
  static List<String> withDocs(Iterable<VaultDoc> docs) {
    final out = [...saved()];
    for (final d in docs) {
      final k = keyOf(d);
      if (!out.any((e) => e.toLowerCase() == k.toLowerCase())) out.add(k);
    }
    return out;
  }
}
