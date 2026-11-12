import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vault_entry.dart';

/// Stores vault entries in Android's encrypted, Keystore-backed
/// EncryptedSharedPreferences — deliberately separate from the app's
/// regular SQLite database, since passwords/tokens need real encryption
/// at rest, not just being one more row in a plain database file.
///
/// All entries live under a single key as a JSON blob. For a personal
/// vault (tens to low hundreds of entries) this is simpler and
/// completely adequate — no need for a second database engine just for
/// this.
/// ভল্টের ডেটা এমনভাবে নষ্ট যে একটাও এন্ট্রি পড়া যায় না (পুরো blob-টাই
/// ভাঙা JSON)। এই অবস্থায় সেভ করলে সব মুছে যেত — তাই সেভ-পাথ লেখা বন্ধ
/// করে এই এক্সেপশন ছোড়ে; UI সেটা ধরে ব্যবহারকারীকে জানায়।
class VaultCorruptException implements Exception {
  @override String toString() => 'ভল্টের ডেটা পড়া যাচ্ছে না';
}

class VaultService {
  static const _key = 'vault_entries_v1';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// শেষ পড়ায় কয়টা এন্ট্রি ভাঙা বলে বাদ গেছে; -1 মানে পুরো blob-টাই
  /// অপঠনযোগ্য। ভল্ট স্ক্রিন এটা দেখে সতর্ক-ব্যানার দেখায়।
  static int lastSkippedCount = 0;

  static Future<List<VaultEntry>> getAll() async {
    try {
      return await _readLenient();
    } catch (_) {
      // পুরো blob-টাই JSON নয় — একটাও এন্ট্রি পড়া যায় না। "খালি" ভেবে
      // ফেরত দিলে পরের সেভে পুরো ভল্ট মুছে যেত; তাই -1 দিয়ে চিহ্নিত করো।
      lastSkippedCount = -1;
      return [];
    }
  }

  /// একটা একটা করে এন্ট্রি পার্স করে — ভাঙা এন্ট্রি বাদ যায়, ভালোগুলো
  /// থাকে। কখনোই পার্স-এররকে "খালি ভল্ট" ধরে না।
  static Future<List<VaultEntry>> _readLenient() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) { lastSkippedCount = 0; return []; }
    final list = jsonDecode(raw) as List;
    final out = <VaultEntry>[];
    var skipped = 0;
    for (final e in list) {
      try {
        out.add(VaultEntry.fromJson(e as Map<String, dynamic>));
      } catch (_) { skipped++; }
    }
    lastSkippedCount = skipped;
    return out;
  }

  /// সেভ-পাথের পড়া: ভাঙা এন্ট্রি বাদ দিয়ে বাকিগুলো নেয়; বাদ পড়া থাকলে
  /// কাঁচা blob আগে আলাদা চাবিতে (quarantine) রেখে দেয়, যাতে ভাঙা
  /// এন্ট্রিও উদ্ধার-অযোগ্য না হয়। পুরো blob নষ্ট হলে লেখা বন্ধ করে
  /// [VaultCorruptException] ছোড়ে — চুপচাপ ওভাররাইট নয়।
  static Future<List<VaultEntry>> _readForWrite() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) { lastSkippedCount = 0; return []; }
    List decoded;
    try {
      decoded = jsonDecode(raw) as List;
    } catch (_) {
      lastSkippedCount = -1;
      throw VaultCorruptException();
    }
    final out = <VaultEntry>[];
    var skipped = 0;
    for (final e in decoded) {
      try {
        out.add(VaultEntry.fromJson(e as Map<String, dynamic>));
      } catch (_) { skipped++; }
    }
    lastSkippedCount = skipped;
    if (skipped > 0) {
      try {
        await _storage.write(
          key: '$_key-quarantine-${DateTime.now().millisecondsSinceEpoch}',
          value: raw,
        );
      } catch (_) {}
    }
    return out;
  }

  static Future<void> _saveAll(List<VaultEntry> entries) async {
    await _storage.write(
      key: _key,
      value: jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
    await _publishAutofillIndex(entries);
  }

  /// Autofill ছাঁকনির (FilteredAutofillService) জন্য: কোন সাইট/অ্যাপের লগইন সেভ আছে তার তালিকা।
  /// শুধু url + টাইটেল — ইউজারনেম, পাসওয়ার্ড বা অন্য গোপন কিছু নয়।
  static Future<void> _publishAutofillIndex(List<VaultEntry> entries) async {
    try {
      final idx = entries
          .where((e) => e.type == 'login')
          .map((e) => {'u': e.url ?? '', 't': e.title})
          .toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('af_index', jsonEncode(idx));
    } catch (_) {}
  }

  /// অ্যাপ চালুর সময় একবার — আগে থেকে থাকা এন্ট্রির তালিকাও ছাঁকনি পেয়ে যায়।
  static Future<void> publishAutofillIndex() async {
    await _publishAutofillIndex(await getAll());
  }

  static Future<void> insert(VaultEntry entry) async {
    final list = await _readForWrite();
    list.add(entry);
    await _saveAll(list);
  }

  /// Bulk add for CSV import: one read and one write for the whole
  /// batch (calling [insert] per entry would re-read and re-encrypt the
  /// entire vault hundreds of times). Uses a *strict* read — unlike
  /// [getAll], which swallows errors and returns an empty list — so if
  /// the stored vault ever failed to parse, this throws instead of
  /// quietly overwriting every existing entry with just the new ones.
  static Future<void> insertMany(List<VaultEntry> entries) async {
    if (entries.isEmpty) return;
    final raw = await _storage.read(key: _key);
    final List<VaultEntry> list;
    if (raw == null || raw.isEmpty) {
      list = [];
    } else {
      final decoded = jsonDecode(raw) as List; // throws if corrupt — intentional
      list = decoded.map((e) => VaultEntry.fromJson(e as Map<String, dynamic>)).toList();
    }
    list.addAll(entries);
    await _saveAll(list);
  }

  /// ব্যাকআপ থেকে রিস্টোরের জন্য মার্জ: একবার পড়ে, একবার লেখে।
  ///  • একই id আছে ও ব্যাকআপের এন্ট্রি নতুন → আপডেট
  ///  • একই id আছে ও পুরোনো/সমান → বাদ
  ///  • id আলাদা কিন্তু হুবহু একই তথ্য → বাদ (ডুপ্লিকেট)
  ///  • নয়তো নতুন যোগ
  /// বর্তমান ভল্ট নষ্ট থাকলেও রিস্টোর আটকায় না — ভাঙা এন্ট্রি বাদ যায়,
  /// পুরো blob নষ্ট হলে সেটা quarantine-এ রেখে খালি থেকে শুরু হয়
  /// (ব্যাকআপের এন্ট্রিই তখন ভরসা)। রিটার্ন: [যোগ, আপডেট, বাদ]
  static Future<List<int>> mergeMany(List<VaultEntry> incoming) async {
    List<VaultEntry> list;
    try {
      list = await _readForWrite();
    } on VaultCorruptException {
      try {
        final raw = await _storage.read(key: _key);
        if (raw != null && raw.isNotEmpty) {
          await _storage.write(
            key: '$_key-quarantine-${DateTime.now().millisecondsSinceEpoch}',
            value: raw,
          );
        }
      } catch (_) {}
      list = [];
    }
    final byId = <String, int>{};
    for (var i = 0; i < list.length; i++) { byId[list[i].id] = i; }
    String sig(VaultEntry e) =>
        '${e.type}\u0001${e.title}\u0001${e.username ?? ''}\u0001${e.secret}\u0001${e.url ?? ''}';
    final sigs = list.map(sig).toSet();

    var added = 0, updated = 0, skipped = 0;
    for (final e in incoming) {
      final idx = byId[e.id];
      if (idx != null) {
        if (e.updatedAt > list[idx].updatedAt) {
          list[idx] = e;
          updated++;
        } else {
          skipped++;
        }
      } else if (sigs.contains(sig(e))) {
        skipped++;
      } else {
        list.add(e);
        byId[e.id] = list.length - 1;
        sigs.add(sig(e));
        added++;
      }
    }
    if (added > 0 || updated > 0) await _saveAll(list);
    return [added, updated, skipped];
  }

  static Future<void> update(VaultEntry entry) async {
    final list = await _readForWrite();
    final idx = list.indexWhere((e) => e.id == entry.id);
    if (idx != -1) {
      list[idx] = entry;
      await _saveAll(list);
    }
  }

  static Future<void> delete(String id) async {
    final list = await _readForWrite();
    list.removeWhere((e) => e.id == id);
    await _saveAll(list);
  }

  /// Every password currently in the vault, for the weak/reused check —
  /// simple local logic, no external service involved.
  static Future<Map<String, int>> duplicateSecretCounts() async {
    final list = await getAll();
    final counts = <String, int>{};
    for (final e in list) {
      if (e.secret.isEmpty) continue;
      counts[e.secret] = (counts[e.secret] ?? 0) + 1;
    }
    return counts;
  }
}
