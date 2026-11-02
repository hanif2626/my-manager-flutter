import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/settings_service.dart';
import 'radar_models.dart';

/// ⭐ স্টার-দেওয়া সার্কুলার। সার্কুলারের পুরো তথ্য ধরে রাখা হয় — তাই ফিড থেকে সরে গেলেও (বা পরে মেয়াদ শেষ হলেও)
/// স্টার-তালিকায় থাকে, আর শেষ তারিখের আগে সতর্কতাও পায়। ফিডে সার্কুলারটা আবার এলে তথ্য হালনাগাদ হয়।
class RadarStars {
  static const key = 'radar_starred';
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Map<String, dynamic> _raw() {
    final s = SettingsService.getString(key);
    if (s.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(Map<String, dynamic> m) async {
    await SettingsService.setString(key, jsonEncode(m));
    changes.value++;
  }

  static Set<String> keysOf(RadarItem i) => {i.url, ...i.altUrls};

  static bool isStarred(RadarItem i) {
    final m = _raw();
    return keysOf(i).any(m.containsKey);
  }

  /// স্টার দেয়/তোলে। ফেরত: এখন স্টার দেওয়া আছে কি না।
  static Future<bool> toggle(RadarItem i) async {
    final m = _raw();
    final hit = keysOf(i).where(m.containsKey).toList();
    if (hit.isNotEmpty) {
      for (final k in hit) {
        m.remove(k);
      }
      await _save(m);
      return false;
    }
    m[i.url] = {'item': i.toMap(), 'at': DateTime.now().millisecondsSinceEpoch};
    await _save(m);
    return true;
  }

  static int get count => _raw().length;

  /// স্টার-তালিকা: চলমান আগে (শেষ তারিখ কাছের আগে), মেয়াদ-শেষ সবার পরে।
  static List<RadarItem> items() {
    final out = <RadarItem>[];
    _raw().forEach((k, v) {
      try {
        final mm = (v as Map)['item'];
        if (mm is Map) out.add(RadarItem.fromMap(Map<String, dynamic>.from(mm)));
      } catch (_) {}
    });
    int rank(RadarItem i) {
      final d = i.daysLeft;
      if (d == null) return 5000;
      return d < 0 ? 10000 - d : d; // মেয়াদ-শেষ: সবার শেষে (সদ্য শেষ আগে)
    }

    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// ফিডে এখন যা আছে তা দিয়ে স্টার-দেওয়া সার্কুলারের তথ্য হালনাগাদ (শেষ তারিখ বাড়লে ইত্যাদি)।
  static Future<void> refreshFrom(List<RadarItem> feed) async {
    final m = _raw();
    if (m.isEmpty) return;
    var changed = false;
    for (final f in feed) {
      for (final k in keysOf(f)) {
        final cur = m[k];
        if (cur is Map) {
          m[k] = {'item': f.toMap(), 'at': cur['at'] ?? DateTime.now().millisecondsSinceEpoch};
          changed = true;
          break;
        }
      }
    }
    if (changed) await SettingsService.setString(key, jsonEncode(m));
  }
}
