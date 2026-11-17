import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ভল্টের নিজস্ব প্যাটার্ন লক (শুধু ভল্টের জন্য — ব্যবহারকারীর
/// নির্দেশ ২০২৬-১১-১৭)। প্যাটার্ন নিজে কোথাও সংরক্ষিত থাকে না:
/// র‍্যান্ডম salt দিয়ে PBKDF2 হ্যাশ করে শুধু হ্যাশটা
/// Keystore-সুরক্ষিত স্টোরেজে রাখা হয়। ফোন আনলক থাকলেও এই
/// প্যাটার্ন ছাড়া ভল্ট স্ক্রিন খোলে না — ফিঙ্গারপ্রিন্টের পরের
/// আলাদা স্তর।
class VaultPatternService {
  static const _key = 'vault_pattern_v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const minDots = 4;

  static Future<bool> isSet() async {
    try {
      final v = await _storage.read(key: _key);
      return v != null && v.contains(':');
    } catch (_) {
      return false;
    }
  }

  static Future<void> setPattern(List<int> dots) async {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final hash = await _hash(dots, salt);
    await _storage.write(
        key: _key, value: '${base64Encode(salt)}:${base64Encode(hash)}');
  }

  static Future<bool> verify(List<int> dots) async {
    try {
      final v = await _storage.read(key: _key);
      if (v == null || !v.contains(':')) return false;
      final parts = v.split(':');
      final salt = base64Decode(parts[0]);
      final expected = base64Decode(parts[1]);
      final actual = await _hash(dots, salt);
      if (actual.length != expected.length) return false;
      var diff = 0;
      for (var i = 0; i < actual.length; i++) {
        diff |= actual[i] ^ expected[i];
      }
      return diff == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }

  static Future<List<int>> _hash(List<int> dots, List<int> salt) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    ).deriveKeyFromPassword(password: dots.join('-'), nonce: salt);
    return key.extractBytes();
  }
}
