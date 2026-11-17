import 'package:flutter/services.dart';

/// অন্য অ্যাপ খোলা / লিংক খোলার জন্য নেটিভ ব্রিজ (MainActivity.kt)।
class AppLauncher {
  static const _ch = MethodChannel('com.hanif.mymanager/launcher');

  static Future<bool> launchApp(String package) async {
    try {
      return (await _ch.invokeMethod<bool>('launchApp', {'package': package})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// ডায়ালার খোলে (নম্বর বসানো অবস্থায়) — সরাসরি কল করে না, তাই কোনো
  /// পারমিশন লাগে না; ব্যবহারকারী নিজে কল বাটনে চাপে।
  static Future<bool> dial(String number) async {
    final n = number.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (n.isEmpty) return false;
    try {
      return (await _ch.invokeMethod<bool>('dial', {'number': n})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// হোম-স্ক্রিন শর্টকাট (আইকনে লং-প্রেস) থেকে আসা গন্তব্য —
  /// একবার পড়লেই শেষ ('authenticator' বা null)।
  static Future<String?> takeLaunchTarget() async {
    try {
      return await _ch.invokeMethod<String>('takeLaunchTarget');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> openUrl(String url) async {
    var u = url.trim();
    if (u.isEmpty) return false;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    try {
      return (await _ch.invokeMethod<bool>('openUrl', {'url': u})) ?? false;
    } catch (_) {
      return false;
    }
  }
}
