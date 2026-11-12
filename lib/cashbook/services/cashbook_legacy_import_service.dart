import 'dart:io';
import '../../services/bubble_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import '../db/cashbook_db.dart';

class LegacyImportPreview {
  final String tempPath;
  final int accountCount;
  final int entryCount;
  LegacyImportPreview({required this.tempPath, required this.accountCount, required this.entryCount});
}

/// Imports data from the "Cash Book"-style app schema this person's old
/// backup used: an `accounts` table (ledger/book names — often auto
/// month-named) and a `cashTransaction` table (date, cash_in, cash_out,
/// notes, accounts). Nothing here is guessed from unfamiliar formats —
/// this maps those exact two tables, and only those.
class CashbookLegacyImportService {
  /// Lets the person pick a .db file, copies it into our own temp
  /// storage (so Android's file-access quirks never get in the way of
  /// re-opening it), and returns row counts to preview before importing
  /// anything. Returns null if they cancelled or the file doesn't look
  /// like this kind of backup.
  static Future<LegacyImportPreview?> pickAndPreview() async {
    final result = await BubblePicker.pickFiles(withData: true);
    final picked = result?.files.single;
    if (picked?.bytes == null) return null;

    final dir = await getTemporaryDirectory();
    final tempPath = '${dir.path}/legacy_cashbook_import.db';
    await File(tempPath).writeAsBytes(picked!.bytes!, flush: true);

    final legacyDb = await sqflite.openDatabase(tempPath, readOnly: true);
    try {
      final tables = await legacyDb.query('sqlite_master',
          where: "type='table' AND name IN ('accounts','cashTransaction')");
      if (tables.length < 2) return null; // not a recognisable Cash Book export

      final accCount = sqflite.Sqflite.firstIntValue(
          await legacyDb.rawQuery('SELECT COUNT(*) FROM accounts'));
      final txCount = sqflite.Sqflite.firstIntValue(
          await legacyDb.rawQuery('SELECT COUNT(*) FROM cashTransaction'));
      return LegacyImportPreview(
          tempPath: tempPath, accountCount: accCount ?? 0, entryCount: txCount ?? 0);
    } finally {
      await legacyDb.close();
    }
  }

  /// Actually performs the import — call only after the person has
  /// confirmed the preview. Returns how many entries were imported.
  static Future<int> import(String tempPath) async {
    final legacyDb = await sqflite.openDatabase(tempPath, readOnly: true);
    try {
      final accountRows = await legacyDb.query('accounts');
      final accountNames = accountRows.map((r) => r['name'] as String).toSet().toList();

      final txRows = await legacyDb.query('cashTransaction');
      final entries = <Map<String, dynamic>>[];
      for (final row in txRows) {
        final cashIn = (row['cash_in'] as num?) ?? 0;
        final cashOut = (row['cash_out'] as num?) ?? 0;
        if (cashIn == 0 && cashOut == 0) continue; // nothing actually moved in this row

        // তারিখ int ছাড়াও TEXT/REAL হতে পারে — cast ব্যর্থ হলে আগে পুরো
        // ইমপোর্ট বাতিল হয়ে যেত; এখন শুধু ওই সারি বাদ যায়।
        final rawDate = row['date'];
        final int? epochMs = rawDate is int
            ? rawDate
            : rawDate is num
                ? rawDate.toInt()
                : rawDate is String
                    ? int.tryParse(rawDate.trim())
                    : null;
        if (epochMs == null) continue;
        // These timestamps are UTC epoch millis; Bangladesh sits at a
        // fixed UTC+6 with no daylight saving, so a flat +6h is exact —
        // no timezone package needed for this one-time conversion.
        final local = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true)
            .add(const Duration(hours: 6));
        final dateStr = '${local.year.toString().padLeft(4, '0')}-'
            '${local.month.toString().padLeft(2, '0')}-'
            '${local.day.toString().padLeft(2, '0')}';

        final rawNote = (row['notes'] as String?)?.trim();
        final accountName = row['accounts'] as String?;
        if (accountName == null) continue; // can't place this entry anywhere

        // একই সারিতে জমা ও খরচ দুটোই থাকলে দুটো আলাদা এন্ট্রি — আগে
        // শুধু জমাটা নেওয়া হতো, খরচটা চিরতরে হারিয়ে যেত।
        void addPart(String type, num amt) {
          entries.add({
            'accountName': accountName,
            'type': type,
            'amount': amt.toDouble(),
            'date': dateStr,
            'note': (rawNote != null && rawNote.isNotEmpty) ? rawNote : 'পুরনো এন্ট্রি',
          });
        }
        if (cashIn > 0) addPart('in', cashIn);
        if (cashOut > 0) addPart('out', cashOut);
      }

      return CashbookDB.importLegacy(accountNames: accountNames, entries: entries);
    } finally {
      await legacyDb.close();
      try { await File(tempPath).delete(); } catch (_) {}
    }
  }
}
