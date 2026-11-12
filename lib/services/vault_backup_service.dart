import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'bubble_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/vault_entry.dart';
import 'drive_service.dart';
import 'settings_service.dart';
import 'vault_service.dart';

/// পাসওয়ার্ড ভল্টের এনক্রিপ্টেড ব্যাকআপ।
///
/// কেন আলাদা: Drive-এর সাধারণ ব্যাকআপ (DriveService.backupDatabase) শুধু
/// SQLite-এর ডাটা (প্রজেক্ট/আইডিয়া/ফাইল) নেয়। ভল্ট থাকে আলাদা
/// Keystore-ব্যাকড secure storage-এ, তাই ফোন হারালে/রিসেট হলে সেটা যেত।
///
/// ফরম্যাট: JSON খাম →
///   { format, v, kdf:"pbkdf2-hmac-sha256", iter, salt, nonce, ct, mac }
/// পাসওয়ার্ড → PBKDF2-HMAC-SHA256 (১.৫ লাখ ধাপ, র‍্যান্ডম salt) → ২৫৬-বিট কী →
/// AES-256-GCM। ব্যাকআপ ফাইল একা থাকলে পাসওয়ার্ড ছাড়া পড়া অসম্ভব, আর
/// কোনো বাইট বদলালে GCM ট্যাগ মিলবে না (টেম্পার ধরা পড়ে)।
class VaultBackupException implements Exception {
  final String message;
  VaultBackupException(this.message);
  @override String toString() => message;
}

class WrongBackupPasswordException extends VaultBackupException {
  WrongBackupPasswordException()
      : super('পাসওয়ার্ড ভুল, অথবা ফাইলটা নষ্ট/বদলে গেছে');
}

class WrongRecoveryAnswerException extends VaultBackupException {
  WrongRecoveryAnswerException() : super('উত্তর মেলেনি');
}

class VaultRestoreResult {
  final int added, updated, skipped, total;
  VaultRestoreResult(this.added, this.updated, this.skipped, this.total);
}

enum VaultDriveResult { success, notSignedIn, noBackup, failed }

class VaultBackupService {
  static const _format = 'mymanager-vault';
  static const _iterations = 150000;
  static const driveFileName = 'mymanager_vault.mmvault';
  static const _lastBackupKey = 'vault_last_backup_ms';
  static const minPasswordLength = 8;
  static const minAnswerLength = 3;
  static const _hintIterations = 200000;
  static const _lastQuestionKey = 'vault_recovery_question';

  /// শেষবার দেওয়া রিকভারি প্রশ্ন (উত্তর কোথাও সেভ হয় না) — পরের ব্যাকআপে আগে থেকে বসানোর জন্য।
  static String lastQuestion() {
    try {
      return SettingsService.getString(_lastQuestionKey);
    } catch (_) {
      return '';
    }
  }

  /// উত্তর মেলানোর আগে স্বাভাবিক করা: ছোট হাতের অক্ষর, বাড়তি স্পেস বাদ।
  /// (যাতে "Dhaka ", "dhaka", "DHAKA" সব একই ধরা হয়)
  static String normalizeAnswer(String a) =>
      a.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');


  static String? lastDriveError() => DriveService.instance.lastError;

  // ───────────────────── শেষ ব্যাকআপের হিসাব ─────────────────────

  static int lastBackupMs() {
    try {
      return SettingsService.getInt(_lastBackupKey, defaultValue: 0);
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _markBackup() async {
    try {
      await SettingsService.setInt(_lastBackupKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  // ───────────────────── এনক্রিপশন (আলাদা isolate-এ) ─────────────────────
  // PBKDF2 ভারী, মূল থ্রেডে চালালে স্পিনার আটকে যেত।

  static Future<String> _encrypt(List<VaultEntry> entries, String password,
      {String? question, String? answer}) {
    final payload = jsonEncode({
      'exported_at': DateTime.now().toIso8601String(),
      'count': entries.length,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    final q = (question ?? '').trim();
    final a = normalizeAnswer(answer ?? '');
    return Isolate.run(() => _encryptPayload(payload, password, _iterations, q, a));
  }

  static Future<String> _encryptPayload(
      String payload, String password, int iter, String question, String answer) async {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256));
    final algo = AesGcm.with256bits();
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    final box = await algo.encrypt(
      utf8.encode(payload),
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode('$_format-v1'),
    );
    final env = <String, dynamic>{
      'format': _format,
      'v': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'iter': iter,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ct': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
    // রিকভারি হিন্ট: ব্যাকআপ পাসওয়ার্ডটাই এনক্রিপ্ট করা হয় প্রশ্নের উত্তর থেকে
    // বানানো কী দিয়ে। ফাইলের ভেতরেই থাকে, তাই নতুন ফোনেও কাজ করে।
    if (question.isNotEmpty && answer.isNotEmpty) {
      final hSalt = List<int>.generate(16, (_) => rnd.nextInt(256));
      final hNonce = List<int>.generate(12, (_) => rnd.nextInt(256));
      final hKey = await Pbkdf2(
        macAlgorithm: Hmac.sha256(), iterations: _hintIterations, bits: 256,
      ).deriveKeyFromPassword(password: answer, nonce: hSalt);
      final hBox = await algo.encrypt(
        utf8.encode(password),
        secretKey: hKey,
        nonce: hNonce,
        aad: utf8.encode('$_format-hint-v1'),
      );
      env['hint'] = {
        'q': question,
        'iter': _hintIterations,
        'salt': base64Encode(hSalt),
        'nonce': base64Encode(hNonce),
        'ct': base64Encode(hBox.cipherText),
        'mac': base64Encode(hBox.mac.bytes),
      };
    }
    return jsonEncode(env);
  }

  // ───────────────────── রিকভারি (প্রশ্ন-উত্তর) ─────────────────────

  /// ব্যাকআপ ফাইলে রিকভারি প্রশ্ন থাকলে সেটা; নইলে null।
  static String? readRecoveryQuestion(String text) {
    try {
      final env = jsonDecode(text) as Map<String, dynamic>;
      if (env['format'] != _format) return null;
      final h = env['hint'];
      if (h is! Map) return null;
      final q = h['q'];
      return (q is String && q.trim().isNotEmpty) ? q : null;
    } catch (_) {
      return null;
    }
  }

  /// উত্তর ঠিক হলে ব্যাকআপের পাসওয়ার্ড ফেরত দেয়; ভুল হলে [WrongRecoveryAnswerException]।
  static Future<String> recoverPassword(String text, String answer) async {
    final Map<String, dynamic> hint;
    try {
      final env = jsonDecode(text) as Map<String, dynamic>;
      hint = Map<String, dynamic>.from(env['hint'] as Map);
    } catch (_) {
      throw VaultBackupException('এই ব্যাকআপে রিকভারি প্রশ্ন সেট করা নেই');
    }
    final iter = hint['iter'];
    if (iter is! int || iter < 1000 || iter > 3000000) {
      throw VaultBackupException('রিকভারি অংশ নষ্ট');
    }
    final a = normalizeAnswer(answer);
    try {
      return await Isolate.run(() => _recoverPayload(hint, a, iter));
    } catch (_) {
      throw WrongRecoveryAnswerException();
    }
  }

  static Future<String> _recoverPayload(Map<String, dynamic> h, String answer, int iter) async {
    final algo = AesGcm.with256bits();
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256,
    ).deriveKeyFromPassword(password: answer, nonce: base64Decode(h['salt'] as String));
    final clear = await algo.decrypt(
      SecretBox(base64Decode(h['ct'] as String),
          nonce: base64Decode(h['nonce'] as String),
          mac: Mac(base64Decode(h['mac'] as String))),
      secretKey: key,
      aad: utf8.encode('$_format-hint-v1'),
    );
    return utf8.decode(clear);
  }

  static Future<List<VaultEntry>> _decrypt(String text, String password) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw VaultBackupException('এটা My Manager ভল্ট ব্যাকআপ ফাইল নয়');
    }
    if (env['format'] != _format) {
      throw VaultBackupException('এটা My Manager ভল্ট ব্যাকআপ ফাইল নয়');
    }
    final iter = env['iter'];
    if (iter is! int || iter < 1000 || iter > 3000000) {
      throw VaultBackupException('ব্যাকআপ ফাইলের হেডার নষ্ট');
    }
    final String clear;
    try {
      clear = await Isolate.run(
          () => _decryptPayload(text, password, iter));
    } catch (_) {
      throw WrongBackupPasswordException();
    }
    try {
      final data = jsonDecode(clear) as Map<String, dynamic>;
      return (data['entries'] as List)
          .map((e) => VaultEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      throw VaultBackupException('ব্যাকআপের ভেতরের ডাটা পড়া যায়নি');
    }
  }

  static Future<String> _decryptPayload(String text, String password, int iter) async {
    final env = jsonDecode(text) as Map<String, dynamic>;
    final salt = base64Decode(env['salt'] as String);
    final nonce = base64Decode(env['nonce'] as String);
    final ct = base64Decode(env['ct'] as String);
    final mac = base64Decode(env['mac'] as String);
    final algo = AesGcm.with256bits();
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    final clear = await algo.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: utf8.encode('$_format-v1'),
    );
    return utf8.decode(clear);
  }

  // ───────────────────── এক্সপোর্ট (ফাইল / শেয়ার) ─────────────────────

  /// ব্যাকআপ করার জন্য ভল্টের সব এন্ট্রি; খালি বা পড়া না গেলে এক্সেপশন
  /// (যাতে খালি ব্যাকআপ বানিয়ে ভুল নিরাপত্তাবোধ না আসে)।
  static Future<List<VaultEntry>> _entriesForBackup() async {
    final list = await VaultService.getAll();
    if (list.isEmpty) {
      if (VaultService.lastSkippedCount == -1) {
        throw VaultBackupException('ভল্টের ডেটা পড়া যাচ্ছে না — ব্যাকআপ নেওয়ার আগে রিস্টোর করো');
      }
      throw VaultBackupException('ভল্ট খালি — ব্যাকআপ নেওয়ার কিছু নেই');
    }
    return list;
  }

  static Future<void> _rememberQuestion(String? q) async {
    if (q == null || q.trim().isEmpty) return;
    try {
      await SettingsService.setString(_lastQuestionKey, q.trim());
    } catch (_) {}
  }

  static Future<int> exportToFile(String password, {String? question, String? answer}) async {
    final entries = await _entriesForBackup();
    final enc = await _encrypt(entries, password, question: question, answer: answer);
    await _rememberQuestion(question);
    final dir = await getTemporaryDirectory();
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'MyManager_Vault_${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}.mmvault';
    final file = File('${dir.path}/$name');
    await file.writeAsString(enc, flush: true);
    await Share.shareXFiles([XFile(file.path)],
        text: '🔐 My Manager ভল্ট ব্যাকআপ (এনক্রিপ্টেড — পাসওয়ার্ড ছাড়া খোলা যায় না)');
    await _markBackup();
    return entries.length;
  }

  // ───────────────────── Google Drive ─────────────────────

  static Future<bool> _ensureDrive() async {
    final ds = DriveService.instance;
    if (ds.isSignedIn) return true;
    if (await ds.signInSilently()) return true;
    return ds.signIn();
  }

  static Future<VaultDriveResult> backupToDrive(String password,
      {String? question, String? answer}) async {
    final entries = await _entriesForBackup();
    if (!await _ensureDrive()) return VaultDriveResult.notSignedIn;
    final enc = await _encrypt(entries, password, question: question, answer: answer);
    await _rememberQuestion(question);
    final r = await DriveService.instance.backupJson(driveFileName, enc);
    if (r == DriveBackupResult.success) {
      await _markBackup();
      return VaultDriveResult.success;
    }
    if (r == DriveBackupResult.notSignedIn) return VaultDriveResult.notSignedIn;
    return VaultDriveResult.failed;
  }

  /// Drive থেকে এনক্রিপ্টেড টেক্সট নামায়। null → সাইন-ইন হয়নি;
  /// খালি স্ট্রিং → ব্যাকআপ নেই/নামানো যায়নি।
  static Future<({VaultDriveResult status, String? text})> fetchFromDrive() async {
    if (!await _ensureDrive()) return (status: VaultDriveResult.notSignedIn, text: null);
    final text = await DriveService.instance.restoreJson(driveFileName);
    if (text == null || text.isEmpty) {
      return (
        status: DriveService.instance.lastError != null
            ? VaultDriveResult.failed
            : VaultDriveResult.noBackup,
        text: null,
      );
    }
    return (status: VaultDriveResult.success, text: text);
  }

  // ───────────────────── রিস্টোর ─────────────────────

  /// ফাইল বাছাই; বাতিল করলে null।
  static Future<String?> pickBackupFile() async {
    final result = await BubblePicker.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.first;
    List<int>? bytes = f.bytes;
    if (bytes == null && f.path != null) bytes = await File(f.path!).readAsBytes();
    if (bytes == null) throw VaultBackupException('ফাইলটা পড়া যায়নি');
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// এনক্রিপ্টেড টেক্সট ডিক্রিপ্ট করে বর্তমান ভল্টে মার্জ করে। বর্তমান
  /// এন্ট্রি কখনো মুছে না — শুধু যোগ/আপডেট।
  static Future<VaultRestoreResult> restoreFromText(String text, String password) async {
    final entries = await _decrypt(text, password);
    final r = await VaultService.mergeMany(entries);
    return VaultRestoreResult(r[0], r[1], r[2], entries.length);
  }
}
