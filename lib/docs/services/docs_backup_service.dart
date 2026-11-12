import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import '../../services/bubble_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/drive_service.dart';
import '../../services/settings_service.dart';
import '../db/docs_db.dart';
import '../models/doc_models.dart';
import 'doc_owners.dart';
import 'docs_crypto.dart';
import 'docs_service.dart';

class DocsBackupException implements Exception {
  final String message;
  DocsBackupException(this.message);
  @override String toString() => message;
}

class DocsRestoreResult {
  final int added, skipped;
  DocsRestoreResult(this.added, this.skipped);
}

/// পাসওয়ার্ড-সুরক্ষিত ডকুমেন্ট ব্যাকআপ (.mmdocs)।
///
/// ফোনের মাস্টার কী ফোনেই বাঁধা, তাই নতুন ফোনে ফাইল খুলতে আলাদা পাসওয়ার্ড-ভিত্তিক
/// ব্যাকআপ লাগে। সব ডকুমেন্ট (মেটাডাটা + নম্বর + ফাইল) এক ZIP-এ, তারপর
/// PBKDF2-HMAC-SHA256 (১.৫ লাখ ধাপ) → AES-256-GCM-এ এনক্রিপ্ট হয়ে একটাই ফাইল।
/// ফাইলটা Drive/Files-এ রাখো; পাসওয়ার্ড ছাড়া কেউ খুলতে পারবে না।
///
/// ফাইল ফরম্যাট: "MMDOCS1" | salt(16) | iter(u32) | nonce(12) | mac(16) | ciphertext
class DocsBackupService {
  static const _magic = 'MMDOCS1';
  // OWASP সুপারিশ — হেডারে iter থাকে, পুরনো ফাইল আগের মানেই খুলবে।
  static const _iterations = 600000;
  static const minPasswordLength = 8;
  static const _lastKey = 'docs_last_backup_ms';

  static int lastBackupMs() {
    try {
      return SettingsService.getInt(_lastKey, defaultValue: 0);
    } catch (_) {
      return 0;
    }
  }

  // ───────────────── এক্সপোর্ট ─────────────────

  static Future<int> exportToFile(String password) async {
    final docs = await DocsDB.all();
    if (docs.isEmpty) throw DocsBackupException('কোনো ডকুমেন্ট নেই — ব্যাকআপ নেওয়ার কিছু নেই');
    final out = await buildSealed(docs, password);

    final dir = await getTemporaryDirectory();
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final file = File('${dir.path}/MyManager_Docs_${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}.mmdocs');
    await file.writeAsBytes(out, flush: true);
    await Share.shareXFiles([XFile(file.path)],
        text: '🗂️ My Manager ডকুমেন্ট ব্যাকআপ (এনক্রিপ্টেড — পাসওয়ার্ড ছাড়া খোলা যায় না)');
    try {
      await SettingsService.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    return docs.length;
  }

  /// [docs]-এর মেটাডাটা + নম্বর + ফাইল এক ZIP-এ, তারপর পাসওয়ার্ড দিয়ে এনক্রিপ্ট। নামের তালিকাও ভেতরে থাকে।
  static Future<Uint8List> buildSealed(List<VaultDoc> docs, String password) async {
    final archive = Archive();
    final meta = <Map<String, dynamic>>[];
    for (final d in docs) {
      final m = d.toMap();
      m['number_plain'] = await DocsService.numberOf(d);
      m.remove('number_enc');
      m['rem'] = '';
      meta.add(m);
      for (final p in d.pages) {
        try {
          final bytes = await DocsCrypto.readFile(p.fileId);
          archive.addFile(ArchiveFile('files/${p.fileId}', bytes.length, bytes));
        } catch (_) {
          // একটা ফাইল নষ্ট হলে বাকিগুলো ঠিকই যাবে।
        }
      }
    }
    final metaBytes = Uint8List.fromList(utf8.encode(jsonEncode({'version': 1, 'docs': meta, 'owners': DocOwners.saved()})));
    archive.addFile(ArchiveFile('meta.json', metaBytes.length, metaBytes));

    // ছবি/PDF আগে থেকেই কম্প্রেসড — ZIP-এ আবার কম্প্রেস করা সময় নষ্ট, তাই NO_COMPRESSION।
    final zip = Uint8List.fromList(ZipEncoder().encode(archive, level: Deflate.NO_COMPRESSION)!);
    return Isolate.run(() => _seal(zip, password));
  }

  // ───────────────── Google Drive: প্রতি নামের আলাদা ফাইল ─────────────────
  //
  // প্রতিটা নামের (হানিফ/সোয়াদ/শিরিন…) জন্য আলাদা এনক্রিপ্টেড ফাইল (mmdocs_<নাম>.enc) — একজনের ব্যাকআপ কখনো
  // আরেকজনের ফাইল ঢাকে না, আর অন্য মডিউলের (প্রজেক্ট/ক্যাশবুক…) ফাইলের সাথেও মেশে না। আপলোড DriveService-এর
  // সুরক্ষিত পথে: ছোট/নষ্ট ফাইলে ঢাকার আগে সংরক্ষিত কপি, প্রতিদিন একটা কপি (শেষ ৭টা), আর পুরনো ভার্সন ফেরানো যায়।
  // ডকুমেন্ট না থাকা নামের জন্য কিছু আপলোড হয় না (ফাঁকা ফাইল দিয়ে ভালো ব্যাকআপ ঢাকা পড়ে না)। রিস্টোর শুধু যোগ করে (মার্জ)।

  static const _drivePrefix = 'mmdocs_';

  static String driveFileName(String owner) =>
      '$_drivePrefix${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}.enc';

  static String? ownerFromDriveName(String file) {
    try {
      if (!file.startsWith(_drivePrefix) || !file.endsWith('.enc')) return null;
      var b = file.substring(_drivePrefix.length, file.length - 4);
      while (b.length % 4 != 0) {
        b += '=';
      }
      return utf8.decode(base64Url.decode(b));
    } catch (_) {
      return null;
    }
  }

  /// প্রতি নামের ব্যাকআপ আলাদাভাবে Drive-এ। একটা ব্যর্থ হলে বাকিগুলো চলে। ফেরত: নাম → ফল।
  static Future<List<({String owner, int docs, bool ok, String? error})>> backupToDrive(
    String password, {
    void Function(String)? onProgress,
  }) async {
    final docs = await DocsDB.all();
    if (docs.isEmpty) throw DocsBackupException('কোনো ডকুমেন্ট নেই — ব্যাকআপ নেওয়ার কিছু নেই');
    final by = <String, List<VaultDoc>>{};
    for (final d in docs) {
      by.putIfAbsent(DocOwners.keyOf(d), () => []).add(d);
    }
    final results = <({String owner, int docs, bool ok, String? error})>[];
    for (final e in by.entries) {
      onProgress?.call('${e.key}-এর ${e.value.length}টা ডকুমেন্ট এনক্রিপ্ট হচ্ছে…');
      try {
        final bytes = await buildSealed(e.value, password);
        onProgress?.call('${e.key}: Drive-এ পাঠানো হচ্ছে…');
        final r = await DriveService.instance.backupBytes(driveFileName(e.key), bytes);
        if (r == DriveBackupResult.notSignedIn) {
          throw DocsBackupException('Google Drive-এ সাইন-ইন করা নেই — ব্যাকআপ কেন্দ্র থেকে সাইন-ইন করো');
        }
        final ok = r == DriveBackupResult.success;
        results.add((owner: e.key, docs: e.value.length, ok: ok, error: ok ? null : (DriveService.instance.lastError ?? 'আপলোড হয়নি')));
      } on DocsBackupException {
        rethrow;
      } catch (err) {
        results.add((owner: e.key, docs: e.value.length, ok: false, error: '$err'));
      }
    }
    if (results.any((r) => r.ok)) {
      try {
        await SettingsService.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
    }
    return results;
  }

  /// Drive-এ থাকা ডকুমেন্ট ব্যাকআপগুলো (প্রতি নামে একটা)।
  static Future<List<({String owner, String file, DateTime time, int size})>> listDriveBackups() async {
    final files = await DriveService.instance.listFilesWithPrefix(_drivePrefix);
    final out = <({String owner, String file, DateTime time, int size})>[];
    for (final f in files) {
      final o = ownerFromDriveName(f.name);
      if (o != null) out.add((owner: o, file: f.name, time: f.time, size: f.size));
    }
    return out;
  }

  static Future<Uint8List> _seal(Uint8List zip, String password) async {
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _iterations, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    final keyBytes = await key.extractBytes();
    final enc = await DocsCrypto.encryptWithKey(zip, keyBytes); // [1][nonce][mac][ct]
    final b = BytesBuilder(copy: false)
      ..add(utf8.encode(_magic))
      ..add(salt)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, _iterations))
      ..add(enc);
    return b.toBytes();
  }

  // ───────────────── রিস্টোর ─────────────────

  static Future<Uint8List?> pickBackupFile() async {
    final r = await BubblePicker.pickFiles(withData: true);
    if (r == null || r.files.isEmpty) return null;
    final f = r.files.first;
    if (f.bytes != null) return f.bytes!;
    if (f.path != null) return File(f.path!).readAsBytes();
    throw DocsBackupException('ফাইলটা পড়া যায়নি');
  }

  static Future<DocsRestoreResult> restore(Uint8List data, String password) async {
    final head = utf8.encode(_magic);
    if (data.length < head.length + 16 + 4 + 29 ||
        utf8.decode(data.sublist(0, head.length), allowMalformed: true) != _magic) {
      throw DocsBackupException('এটা My Manager ডকুমেন্ট ব্যাকআপ ফাইল নয়');
    }
    final Archive archive;
    try {
      final zip = await Isolate.run(() => _open(data, password));
      archive = ZipDecoder().decodeBytes(zip);
    } catch (_) {
      throw DocsBackupException('পাসওয়ার্ড ভুল, অথবা ফাইলটা নষ্ট');
    }

    final metaFile = archive.findFile('meta.json');
    if (metaFile == null) throw DocsBackupException('ব্যাকআপের ভেতরের তথ্য পাওয়া যায়নি');
    final meta = jsonDecode(utf8.decode(metaFile.content as List<int>)) as Map<String, dynamic>;

    for (final o in (meta['owners'] as List? ?? const [])) {
      await DocOwners.add(o.toString());
    }
    final have = (await DocsDB.all()).map((d) => d.id).toSet();
    var added = 0, skipped = 0;
    for (final raw in (meta['docs'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final id = m['id'] as String;
      if (have.contains(id)) {
        skipped++;
        continue;
      }
      final plainNumber = (m.remove('number_plain') as String?) ?? '';
      m['number_enc'] = '';
      m['rem'] = '';
      final doc = VaultDoc.fromMap(m);
      // প্রতিটা ফাইল এই ফোনের নিজের কী দিয়ে নতুন করে এনক্রিপ্ট।
      for (final p in doc.pages) {
        final f = archive.findFile('files/${p.fileId}');
        if (f != null) {
          await DocsCrypto.saveFile(Uint8List.fromList(f.content as List<int>), fileId: p.fileId);
        }
      }
      doc.pages.removeWhere((p) => archive.findFile('files/${p.fileId}') == null);
      await DocsService.save(doc, number: plainNumber); // নম্বর এনক্রিপ্ট + মেয়াদের রিমাইন্ডার নতুন করে
      if (doc.owner.trim().isNotEmpty) await DocOwners.add(doc.owner.trim());
      added++;
    }
    return DocsRestoreResult(added, skipped);
  }

  static Future<Uint8List> _open(Uint8List data, String password) async {
    var o = utf8.encode(_magic).length;
    final salt = data.sublist(o, o + 16);
    o += 16;
    final iter = data.buffer.asByteData(data.offsetInBytes + o, 4).getUint32(0);
    o += 4;
    if (iter < 1000 || iter > 3000000) throw const FormatException('হেডার নষ্ট');
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iter, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
    final keyBytes = await key.extractBytes();
    return DocsCrypto.decryptWithKey(Uint8List.sublistView(data, o), keyBytes);
  }
}
