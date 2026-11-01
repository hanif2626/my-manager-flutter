import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../db/db_helper.dart';
import 'settings_service.dart';
import 'safety_net.dart';

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  GoogleAuthClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

/// Drive-এ রাখা ব্যাকআপের একটা সংস্করণ: মূল ফাইলের পুরনো revision, অথবা অ্যাপের রাখা "সংরক্ষিত কপি"।
class BackupVersion {
  final String? fileId;
  final String? revisionId;
  final DateTime time;
  final int size;
  final String label;
  const BackupVersion({this.fileId, this.revisionId, required this.time, required this.size, required this.label});
  String get key => '${fileId ?? ''}|${revisionId ?? ''}';
}

class DriveService {
  static const _folderName = 'MyManager_Backup';
  static DriveService? _instance;
  static DriveService get instance => _instance ??= DriveService._();
  DriveService._();

  /// The real exception message from the last failed operation, so the UI
  /// can show something more useful than a generic "failed" message.
  String? lastError;

  final _googleSignIn = GoogleSignIn(scopes: [drive.DriveApi.driveFileScope]);
  drive.DriveApi? _driveApi;
  GoogleSignInAccount? _account;
  String? _backupFolderId;

  bool get isSignedIn => _account != null && _driveApi != null;
  String? get userEmail => _account?.email;

  // ── SIGN IN ────────────────────────────────────────────
  Future<bool> signIn() async {
    try {
      lastError = null;
      _account = await _googleSignIn.signIn();
      if (_account == null) {
        lastError = 'সাইন-ইন বাতিল করা হয়েছে';
        return false;
      }
      await _initApi();
      return true;
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService signIn error: $e');
      return false;
    }
  }

  Future<bool> signInSilently() async {
    try {
      _account = await _googleSignIn.signInSilently();
      if (_account == null) return false;
      await _initApi();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// সাইন-ইন না থাকলে আগে চুপচাপ (silent) চেষ্টা করে; [interactive] true হলে
  /// তাতেও না হলে Google অ্যাকাউন্ট বাছাইয়ের পর্দা দেখায়।
  /// অ্যাপ নতুন করে চালুর পর [isSignedIn] false থাকে — তাই ব্যাকআপ/রিস্টোরের আগে এটা ডাকা দরকার।
  Future<bool> ensureSignedIn({bool interactive = false}) async {
    if (isSignedIn) return true;
    if (await signInSilently()) return true;
    if (interactive) return signIn();
    return false;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _account = null;
    _driveApi = null;
    _backupFolderId = null;
  }

  Future<void> _initApi() async {
    if (_account == null) return;
    final auth = await _account!.authentication;
    final headers = {'Authorization': 'Bearer ${auth.accessToken}'};
    _driveApi = drive.DriveApi(GoogleAuthClient(headers));
    _backupFolderId = await _ensureFolder();
  }

  // ── FOLDER ────────────────────────────────────────────
  Future<String?> _ensureFolder() async {
    if (_driveApi == null) return null;
    try {
      final q = "mimeType='application/vnd.google-apps.folder' and name='$_folderName' and trashed=false";
      final list = await _driveApi!.files.list(q: q, $fields: 'files(id,name)', orderBy: 'createdTime');
      if (list.files != null && list.files!.isNotEmpty) {
        return list.files!.first.id;
      }
      final folder = drive.File()
        ..name = _folderName
        ..mimeType = 'application/vnd.google-apps.folder';
      final created = await _driveApi!.files.create(folder, $fields: 'id');
      return created.id;
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService _ensureFolder error: $e');
      return null;
    }
  }

  // ── BACKUP DB ─────────────────────────────────────────
  Future<DriveBackupResult> backupDatabase() async {
    if (!isSignedIn) return DriveBackupResult.notSignedIn;
    try {
      lastError = null;
      // Refresh auth
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) {
        lastError = 'Backup ফোল্ডার তৈরি/খুঁজে পাওয়া যায়নি';
        return DriveBackupResult.failed;
      }

      final dbPath = p.join(await getDatabasesPath(), 'mymanager.db');
      final dbFile = File(dbPath);
      if (!await dbFile.exists()) {
        lastError = 'লোকাল ডেটাবেজ ফাইল খুঁজে পাওয়া যায়নি';
        return DriveBackupResult.failed;
      }

      // Export all data as JSON
      final jsonData = await _exportAllDataAsJson();
      // ফাঁকা/অনেক ছোট ডেটা দিয়ে Drive-এর ভালো ব্যাকআপ ঢেকে ফেলা ঠেকানো — _uploadGuarded দেখো
      return await _uploadGuarded('mymanager_backup.json', jsonData);
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService backup error: $e');
      return DriveBackupResult.failed;
    }
  }

  // ── RESTORE ───────────────────────────────────────────
  Future<DriveBackupResult> restoreFromDrive({BackupVersion? version}) async {
    try {
      lastError = null;
      final jsonData = await restoreJson('mymanager_backup.json', version: version);
      if (jsonData == null) {
        return lastError == null ? DriveBackupResult.noBackup : DriveBackupResult.failed;
      }
      return await restoreFromText(jsonData);
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService restore error: $e');
      return DriveBackupResult.failed;
    }
  }

  /// প্রজেক্ট/আইডিয়ার ডেটা [jsonData] দিয়ে বদলায়। সুরক্ষা: (১) ব্যাকআপ ফাঁকা আর অ্যাপে ডেটা থাকলে বদলায় না;
  /// (২) বদলানোর আগে বর্তমান ডেটার কপি ফোনে রাখে।
  Future<DriveBackupResult> restoreFromText(String jsonData) async {
    final backupN = SafetyNet.itemCount(jsonData) ?? 0;
    final localN = await _localItemCount();
    if (backupN == 0 && localN > 0) {
      lastError = 'এই ব্যাকআপ ফাঁকা (প্রজেক্ট/আইডিয়া ০টি), কিন্তু অ্যাপে এখন ${localN}টি আইটেম আছে — ডেটা বাঁচাতে ফেরানো হয়নি';
      return DriveBackupResult.failed;
    }
    try {
      if (localN > 0) await SafetyNet.snapshot('main', await _exportAllDataAsJson());
    } catch (_) {}
    await _importFromJson(jsonData);
    return DriveBackupResult.success;
  }

  Future<int> _localItemCount() async {
    try {
      final d = await DBHelper.db;
      var n = 0;
      for (final t in ['projects', 'ideas', 'idea_files', 'project_versions']) {
        n += Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM $t')) ?? 0;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  // ── EXPORT JSON ───────────────────────────────────────
  Future<String> _exportAllDataAsJson() async {
    final d = await DBHelper.db;
    final projects = await d.query('projects');
    final ideas = await d.query('ideas');
    final versions = await d.query('project_versions');

    // idea_files one row at a time, not `d.query('idea_files')` in one
    // go — some attachments (photos, PDFs) are large enough on their own
    // that batching many rows together overflows Android's CursorWindow
    // ("Row too big to fit into CursorWindow"). Querying by id
    // individually gives each row its own fresh window instead.
    final fileIds = await d.query('idea_files', columns: ['id']);
    final files = <Map<String, dynamic>>[];
    for (final idRow in fileIds) {
      final rows = await d.query('idea_files', where: 'id = ?', whereArgs: [idRow['id']]);
      if (rows.isNotEmpty) files.add(rows.first);
    }

    return jsonEncode({
      'version': 3,
      'exported_at': DateTime.now().toIso8601String(),
      'projects': projects,
      'ideas': ideas,
      'idea_files': files,
      'project_versions': versions,
    });
  }

  Future<void> _importFromJson(String jsonData) async {
    final data = jsonDecode(jsonData) as Map<String, dynamic>;
    final d = await DBHelper.db;

    await d.transaction((txn) async {
      await txn.delete('idea_files');
      await txn.delete('project_versions');
      await txn.delete('ideas');
      await txn.delete('projects');

      for (final row in (data['projects'] as List)) {
        await txn.insert('projects', Map<String, dynamic>.from(row));
      }
      for (final row in (data['ideas'] as List)) {
        await txn.insert('ideas', Map<String, dynamic>.from(row));
      }
      for (final row in (data['idea_files'] as List)) {
        await txn.insert('idea_files', Map<String, dynamic>.from(row));
      }
      if (data['project_versions'] != null) {
        for (final row in (data['project_versions'] as List)) {
          await txn.insert('project_versions', Map<String, dynamic>.from(row));
        }
      }
    });
  }

  // ── GENERIC NAMED-JSON BACKUP (used by the Cashbook module, which
  // keeps its own separate database and therefore its own backup file
  // rather than being folded into _exportAllDataAsJson above) ────────
  /// একই নামে একাধিক ফাইল থাকলে (আগের রেস-কন্ডিশনে তৈরি) সবচেয়ে নতুনটা — রিস্টোরে পুরনো
  /// ফাইল উঠে আসা ঠেকাতে modifiedTime অনুযায়ী সাজানো।
  Future<String?> _findNewestFileId(String fileName) async {
    final q = "name='$fileName' and '${_backupFolderId!}' in parents and trashed=false";
    final list = await _driveApi!.files.list(q: q, $fields: 'files(id,modifiedTime)', orderBy: 'modifiedTime desc');
    if (list.files == null || list.files!.isEmpty) return null;
    return list.files!.first.id;
  }

  // একসাথে দুটো ব্যাকআপ চললে দুটোই "ফাইল নেই" দেখে দুটো ফাইল বানিয়ে ফেলত; তাই লাইনে দাঁড় করানো।
  Future<void> _backupQueue = Future.value();

  Future<DriveBackupResult> backupJson(String fileName, String jsonData) {
    final run = _backupQueue.then((_) => _backupJsonNow(fileName, jsonData));
    _backupQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<DriveBackupResult> _backupJsonNow(String fileName, String jsonData) async {
    if (!await ensureSignedIn()) return DriveBackupResult.notSignedIn;
    try {
      lastError = null;
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) {
        lastError ??= 'Backup ফোল্ডার তৈরি/খুঁজে পাওয়া যায়নি';
        return DriveBackupResult.failed;
      }
      return await _uploadGuarded(fileName, jsonData);
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService backupJson error: $e');
      return DriveBackupResult.failed;
    }
  }

  /// null → সাইন-ইন নেই / ফাইল নেই / ত্রুটি; কারণটা [lastError]-এ থাকে।
  Future<String?> restoreJson(String fileName, {BackupVersion? version}) async {
    // প্রিভিউয়ে নামানো একই ভার্সন হলে আবার নামাই না
    if (version != null && _previewKey == '$fileName|${version.key}' && _previewText != null) {
      final t = _previewText;
      _previewKey = null;
      _previewText = null;
      return t;
    }
    final bytes = await _downloadBytes(fileName, version);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (e) {
      lastError = 'ফাইল পড়া যায়নি: $e';
      return null;
    }
  }

  Future<List<int>?> _downloadBytes(String fileName, BackupVersion? version) async {
    // সাইন-ইন না থাকলে আগে চুপচাপ, না হলে অ্যাকাউন্ট বাছাইয়ের পর্দা — রিস্টোর হাতে চালানো কাজ।
    if (!await ensureSignedIn(interactive: true)) {
      lastError ??= 'Google Drive-এ সাইন-ইন করা নেই';
      return null;
    }
    try {
      lastError = null;
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) {
        lastError ??= 'Backup ফোল্ডার খুঁজে পাওয়া যায়নি';
        return null;
      }
      final id = version?.fileId ?? await _findNewestFileId(fileName);
      if (id == null) {
        lastError = 'Drive-এর MyManager_Backup ফোল্ডারে $fileName নেই';
        return null;
      }
      final media = (version?.revisionId != null
          ? await _driveApi!.revisions.get(id, version!.revisionId!, downloadOptions: drive.DownloadOptions.fullMedia)
          : await _driveApi!.files.get(id, downloadOptions: drive.DownloadOptions.fullMedia)) as drive.Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) { bytes.addAll(chunk); }
      return bytes;
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService download error: $e');
      return null;
    }
  }

  // ── সব ব্যাকআপ ফাইলের শেষ পরিবর্তনের সময় (ব্যাকআপ কেন্দ্রের জন্য) ───────
  /// MyManager_Backup ফোল্ডারের প্রতিটা ফাইলের নাম → Drive-এ শেষ আপডেটের সময়।
  /// একটাই অনুরোধ। সাইন-ইন না থাকলে বা ব্যর্থ হলে ফাঁকা ম্যাপ।
  // ── সুরক্ষা: ভালো ব্যাকআপ ফাঁকা/ছোট ডেটা দিয়ে ঢাকা পড়া ঠেকানো ────────────────

  String? _previewKey;
  String? _previewText;

  /// আপলোড: Drive-এ আগের ব্যাকআপ থাকলে —
  ///  • নতুন ডেটা পুরোপুরি ফাঁকা (সব তালিকা ০) আর আগেরটায় ডেটা আছে → আপলোড বন্ধ, আগেরটা অক্ষত (failed + কারণ)
  ///  • নতুন ডেটা আগের অর্ধেকেরও কম → আগেরটার "সংরক্ষিত কপি" (শেষ ৫টা) রেখে তবে ঢাকে
  /// যাচাই-ব্যবস্থা নিজে ব্যর্থ হলে আপলোড আটকায় না।
  // একই ডেটা বারবার আপলোড করলে Drive-এর পুরনো ভালো ভার্সন (প্রায় ৩০ দিন/১০০টা পর্যন্ত রাখে) ঠেলে বেরিয়ে যায় —
  // তাই এই চালুর সময়ে আগেরবার যে ডেটা (exported_at বাদে) পাঠানো হয়েছে হুবহু সেটা হলে আর পাঠাই না।
  final Map<String, int> _lastHash = {};

  static int _stableHash(String json) {
    final t = json.replaceAll(RegExp(r'"exported_at"\s*:\s*"[^"]*"\s*,?'), '');
    var h = 5381;
    for (final c in t.codeUnits) {
      h = ((h * 33) ^ c) & 0x7fffffff;
    }
    return h ^ t.length;
  }

  Future<DriveBackupResult> _uploadGuarded(String fileName, String jsonData) async {
    final hash = _stableHash(jsonData);
    if (_lastHash[fileName] == hash) return DriveBackupResult.success; // আগেরবারের হুবহু একই ডেটা
    final res = await _uploadGuardedNow(fileName, jsonData);
    if (res == DriveBackupResult.success) _lastHash[fileName] = hash;
    return res;
  }

  Future<DriveBackupResult> _uploadGuardedNow(String fileName, String jsonData) =>
      _uploadBytesNow(fileName, utf8.encode(jsonData), SafetyNet.itemCount(jsonData));

  /// সব আপলোডের মূল সুরক্ষিত পথ (JSON ও বাইনারি — ডকুমেন্ট ব্যাকআপও এখান দিয়ে)।
  ///  • [newCount] == 0 (তালিকা সব ফাঁকা) আর আগেরটায় ডেটা → আপলোড বন্ধ।
  ///  • নতুনটা আগের অর্ধেকেরও কম → ঢাকার আগে সংরক্ষিত কপি।
  ///  • আগের কপির বয়স ২৪ ঘণ্টার বেশি → প্রতিদিন অন্তত একবার সংরক্ষিত কপি (শেষ ৭টা থাকে) — যাতে ভুল/নষ্ট ডেটা
  ///    ঢুকে গেলেও গত এক সপ্তাহের যেকোনো দিনের ভালো ব্যাকআপ ফেরানো যায়।
  Future<DriveBackupResult> _uploadBytesNow(String fileName, List<int> bytes, int? newCount) async {
    final existingId = await _findNewestFileId(fileName);
    if (existingId != null) {
      try {
        final meta = await _driveApi!.files.get(existingId, $fields: 'size') as drive.File;
        final remoteSize = int.tryParse(meta.size ?? '') ?? 0;
        if (newCount == 0 && remoteSize > bytes.length + 200) {
          lastError = '⚠️ অ্যাপে এখন কোনো ডেটা নেই, কিন্তু Drive-এর আগের ব্যাকআপে ডেটা আছে — ওটা ঢাকা হয়নি। '
              'আগের ডেটা ফিরে পেতে "ফিরিয়ে আনো" বা "পুরনো ভার্সন" চাপো।';
          return DriveBackupResult.failed;
        }
        final shrink = remoteSize >= 2000 && bytes.length * 2 < remoteSize;
        final dayKey = 'drive_copy_ms_$fileName';
        final last = SettingsService.getInt(dayKey);
        final dailyDue = DateTime.now().millisecondsSinceEpoch - last > 24 * 3600 * 1000;
        if (shrink || (dailyDue && remoteSize > 200)) {
          await _saveCopy(existingId, fileName);
          await SettingsService.setInt(dayKey, DateTime.now().millisecondsSinceEpoch);
        }
      } catch (e) {
        debugPrint('DriveService guard check failed: $e');
      }
      await _driveApi!.files.update(
        drive.File(), existingId,
        uploadMedia: drive.Media(Stream.value(bytes), bytes.length), $fields: 'id',
      );
    } else {
      final f = drive.File()..name = fileName..parents = [_backupFolderId!];
      await _driveApi!.files.create(f,
          uploadMedia: drive.Media(Stream.value(bytes), bytes.length), $fields: 'id');
    }
    return DriveBackupResult.success;
  }

  /// বাইনারি ফাইল (যেমন এনক্রিপ্টেড ডকুমেন্ট ব্যাকআপ) সুরক্ষিতভাবে আপলোড — নিজের আলাদা ফাইলে।
  Future<DriveBackupResult> backupBytes(String fileName, Uint8List bytes) {
    final run = _backupQueue.then((_) => _backupBytesNow(fileName, bytes));
    _backupQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<DriveBackupResult> _backupBytesNow(String fileName, Uint8List bytes) async {
    if (!await ensureSignedIn(interactive: true)) return DriveBackupResult.notSignedIn;
    try {
      lastError = null;
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) {
        lastError ??= 'Backup ফোল্ডার তৈরি/খুঁজে পাওয়া যায়নি';
        return DriveBackupResult.failed;
      }
      return await _uploadBytesNow(fileName, bytes, null);
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService backupBytes error: $e');
      return DriveBackupResult.failed;
    }
  }

  /// বাইনারি ফাইল নামায় (null → ফাইল/সাইন-ইন নেই বা ত্রুটি; কারণ [lastError]-এ)।
  Future<Uint8List?> restoreBytes(String fileName, {BackupVersion? version}) async {
    final b = await _downloadBytes(fileName, version);
    return b == null ? null : Uint8List.fromList(b);
  }

  /// ফোল্ডারে নামের শুরু [prefix] এমন ফাইলের তালিকা (সংরক্ষিত কপি বাদে), নতুন আগে।
  Future<List<({String name, DateTime time, int size})>> listFilesWithPrefix(String prefix) async {
    final out = <({String name, DateTime time, int size})>[];
    if (!await ensureSignedIn(interactive: true)) return out;
    try {
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) return out;
      final q = "name contains '$prefix' and '${_backupFolderId!}' in parents and trashed=false";
      final list = await _driveApi!.files.list(q: q, $fields: 'files(name,modifiedTime,size)', orderBy: 'modifiedTime desc', pageSize: 100);
      for (final f in list.files ?? const <drive.File>[]) {
        final n = f.name ?? '';
        if (!n.startsWith(prefix) || n.contains('.saved-')) continue;
        out.add((name: n, time: f.modifiedTime?.toLocal() ?? DateTime.now(), size: int.tryParse(f.size ?? '') ?? 0));
      }
    } catch (e) {
      lastError = e.toString();
    }
    return out;
  }

  Future<void> _saveCopy(String fileId, String fileName) async {
    try {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
      await _driveApi!.files.copy(
        drive.File()..name = '$fileName.saved-$stamp'..parents = [_backupFolderId!],
        fileId,
        $fields: 'id',
      );
      final q = "name contains '$fileName.saved-' and '${_backupFolderId!}' in parents and trashed=false";
      final list = await _driveApi!.files.list(q: q, $fields: 'files(id,createdTime)', orderBy: 'createdTime desc', pageSize: 30);
      final old = list.files ?? const <drive.File>[];
      for (var i = 7; i < old.length; i++) {
        if (old[i].id != null) await _driveApi!.files.delete(old[i].id!);
      }
    } catch (e) {
      debugPrint('DriveService saveCopy failed: $e');
    }
  }

  /// এক ফাইলের সব সংস্করণ (নতুন আগে): এখনকার, Drive-এর পুরনো revision, আর অ্যাপের "সংরক্ষিত কপি"।
  Future<List<BackupVersion>> listVersions(String fileName) async {
    final out = <BackupVersion>[];
    if (!isSignedIn) return out;
    try {
      lastError = null;
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) return out;
      final id = await _findNewestFileId(fileName);
      if (id != null) {
        final cur = await _driveApi!.files.get(id, $fields: 'modifiedTime,size') as drive.File;
        final curTime = cur.modifiedTime?.toLocal() ?? DateTime.now();
        out.add(BackupVersion(fileId: id, time: curTime, size: int.tryParse(cur.size ?? '') ?? 0, label: 'এখনকার ব্যাকআপ'));
        try {
          final revs = await _driveApi!.revisions.list(id, $fields: 'revisions(id,modifiedTime,size)', pageSize: 200);
          for (final r in revs.revisions ?? const <drive.Revision>[]) {
            final t = r.modifiedTime?.toLocal();
            if (t == null || r.id == null) continue;
            // সর্বশেষ revision মানেই "এখনকার" — একই সময়ের হলে দুবার দেখাই না
            if ((t.difference(curTime).inSeconds).abs() <= 2) continue;
            out.add(BackupVersion(fileId: id, revisionId: r.id, time: t, size: int.tryParse(r.size ?? '') ?? 0, label: 'Drive-এর পুরনো ভার্সন'));
          }
        } catch (e) {
          debugPrint('DriveService revisions failed: $e');
        }
      }
      final q = "name contains '$fileName.saved-' and '${_backupFolderId!}' in parents and trashed=false";
      final saved = await _driveApi!.files.list(q: q, $fields: 'files(id,modifiedTime,size)', orderBy: 'createdTime desc', pageSize: 20);
      for (final f in saved.files ?? const <drive.File>[]) {
        if (f.id == null) continue;
        out.add(BackupVersion(
            fileId: f.id,
            time: f.modifiedTime?.toLocal() ?? DateTime.now(),
            size: int.tryParse(f.size ?? '') ?? 0,
            label: 'অ্যাপের রাখা সংরক্ষিত কপি'));
      }
      out.sort((a, b) => b.time.compareTo(a.time));
    } catch (e) {
      lastError = e.toString();
      debugPrint('DriveService listVersions error: $e');
    }
    return out;
  }

  /// একটা সংস্করণ নামিয়ে লেখাটা ফেরত দেয় (ফেরানোর আগে ভেতরে কী আছে দেখাতে); একই লেখা ফেরানোর সময় আবার নামে না।
  Future<String?> previewVersion(String fileName, BackupVersion version) async {
    _previewKey = null;
    _previewText = null;
    final t = await restoreJson(fileName, version: version);
    if (t != null) {
      _previewKey = '$fileName|${version.key}';
      _previewText = t;
    }
    return t;
  }

  Future<Map<String, DateTime>> listBackupTimes() async {
    if (!isSignedIn) return {};
    try {
      await _initApi();
      _backupFolderId ??= await _ensureFolder();
      if (_backupFolderId == null) return {};
      final q = "'${_backupFolderId!}' in parents and trashed=false";
      final list = await _driveApi!.files.list(q: q, $fields: 'files(name,modifiedTime)', pageSize: 100);
      final out = <String, DateTime>{};
      for (final f in list.files ?? const <drive.File>[]) {
        if (f.name != null && f.modifiedTime != null) {
          out[f.name!] = f.modifiedTime!.toLocal();
        }
      }
      return out;
    } catch (e) {
      lastError = e.toString();
      return {};
    }
  }

  // ── LAST BACKUP TIME ──────────────────────────────────
  Future<DateTime?> getLastBackupTime() async {
    if (!isSignedIn || _backupFolderId == null) return null;
    try {
      await _initApi();
      final q = "name='mymanager_backup.json' and '${_backupFolderId!}' in parents and trashed=false";
      final list = await _driveApi!.files.list(q: q, $fields: 'files(modifiedTime)');
      if (list.files != null && list.files!.isNotEmpty) {
        return list.files!.first.modifiedTime;
      }
    } catch (e) { /**/ }
    return null;
  }
}

enum DriveBackupResult { success, failed, notSignedIn, noBackup }
