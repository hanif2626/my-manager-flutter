import 'dart:convert';
import 'dart:io';
import 'bubble_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/vault_entry.dart';
import 'vault_service.dart';

class VaultCsvImportResult {
  final int imported;
  final int duplicates; // already in the vault (or repeated in the file)
  final int skipped; // no usable title/password
  final bool headerRecognized;
  VaultCsvImportResult({
    required this.imported,
    required this.duplicates,
    required this.skipped,
    required this.headerRecognized,
  });
}

/// CSV is plaintext — exporting writes every password out in the clear,
/// exactly like Chrome's or Google Password Manager's own export. That
/// is the whole point of a portable format, but it means the resulting
/// file is exactly as sensitive as the vault itself; the UI side
/// (vault_screen.dart) warns before calling [exportCsv].
///
/// The parser below is hand-written on purpose rather than using a CSV
/// package's auto-detection: real password exports are full of quotes,
/// apostrophes, '#', commas and newlines inside fields, and guessing
/// the quote character or line ending from the "first occurrence" gets
/// that wrong — an earlier version did, and silently parsed a whole
/// export as a single row (0 imported, 0 skipped).
class VaultCsvService {
  // First five columns intentionally identical to Google Password
  // Manager / Chrome exports so the file can round-trip with them.
  static const _exportHeader = ['name', 'url', 'username', 'password', 'note', 'type'];

  static String _quote(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  static Future<void> exportCsv(List<VaultEntry> entries) async {
    final b = StringBuffer();
    b.write('${_exportHeader.join(',')}\r\n');
    for (final e in entries) {
      b.write([
        _quote(e.title),
        _quote(e.url ?? ''),
        _quote(e.username ?? ''),
        _quote(e.secret),
        _quote(e.notes ?? ''),
        _quote(e.type),
      ].join(','));
      b.write('\r\n');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/vault_export.csv');
    await file.writeAsString(b.toString(), encoding: utf8);
    await Share.shareXFiles([XFile(file.path)],
        text: 'My Manager ভল্ট এক্সপোর্ট — এই ফাইলে পাসওয়ার্ড প্লেইন টেক্সটে আছে, সাবধানে রাখুন');
  }

  /// Minimal RFC 4180 parser: quoted fields, "" as an escaped quote,
  /// commas/newlines inside quotes, and both \r\n and \n (and a lone \r)
  /// as row breaks. A quote character in the *middle* of an unquoted
  /// field is kept literally (real-world passwords contain them).
  @visibleForTesting
  static List<List<String>> parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;
    final n = text.length;
    var i = 0;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < n) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < n && text[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.write(c);
        i++;
        continue;
      }
      if (c == '"' && !fieldStarted) {
        inQuotes = true;
        fieldStarted = true;
        i++;
        continue;
      }
      if (c == ',') {
        endField();
        i++;
        continue;
      }
      if (c == '\r') {
        // CRLF: let the following \n end the row. Lone CR: treat as a break.
        if (i + 1 < n && text[i + 1] == '\n') {
          i++;
          continue;
        }
        endRow();
        i++;
        continue;
      }
      if (c == '\n') {
        endRow();
        i++;
        continue;
      }
      field.write(c);
      fieldStarted = true;
      i++;
    }
    if (fieldStarted || field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }

  /// Recognises this app's own headers and the common aliases used by
  /// Google/Chrome/Bitwarden-style exports.
  static const _aliases = {
    'type': ['type'],
    'title': ['title', 'name'],
    'username': ['username', 'login_username', 'user', 'login'],
    'secret': ['secret', 'password', 'login_password', 'pass'],
    'url': ['url', 'uri', 'login_uri', 'website', 'web site'],
    'notes': ['notes', 'note', 'comment', 'comments'],
  };

  static String _hostOf(String url) {
    var u = url.trim();
    u = u.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    return u.split('/').first;
  }

  /// [onFilePicked] fires after the person has chosen a file and before
  /// the (potentially few-second) parse+save, so the caller can show a
  /// progress indicator only for that part — not while the system file
  /// picker itself is open. Returns null if they cancelled.
  static Future<VaultCsvImportResult?> pickAndImport({VoidCallback? onFilePicked}) async {
    final result = await BubblePicker.pickFiles(withData: true);
    final picked = result?.files.single;
    if (picked?.bytes == null) return null;
    onFilePicked?.call();

    // Proper UTF-8 (Bengali, emoji, etc.) and drop a leading BOM if the
    // exporting app added one — a BOM would otherwise glue itself onto
    // the first header name and make "name" unrecognisable.
    var text = utf8.decode(picked!.bytes!, allowMalformed: true);
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);

    final rows = parseCsv(text);
    if (rows.isEmpty) {
      return VaultCsvImportResult(imported: 0, duplicates: 0, skipped: 0, headerRecognized: false);
    }

    final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
    final colIndex = <String, int>{};
    _aliases.forEach((field, names) {
      for (final n in names) {
        final i = header.indexOf(n);
        if (i != -1) {
          colIndex[field] = i;
          break;
        }
      }
    });
    final headerOk = colIndex.containsKey('secret') &&
        (colIndex.containsKey('title') || colIndex.containsKey('url'));
    if (!headerOk) {
      return VaultCsvImportResult(imported: 0, duplicates: 0, skipped: 0, headerRecognized: false);
    }

    String cell(List<String> row, String field) {
      final i = colIndex[field];
      if (i == null || i >= row.length) return '';
      return row[i];
    }

    String keyOf(String type, String title, String user, String secret, String url) =>
        '$type|$title|$user|$secret|$url';

    final existing = await VaultService.getAll();
    final seen = <String>{
      for (final e in existing)
        keyOf(e.type, e.title.trim(), (e.username ?? '').trim(), e.secret, (e.url ?? '').trim()),
    };

    final newEntries = <VaultEntry>[];
    int duplicates = 0, skipped = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final row in rows.skip(1)) {
      if (row.every((c) => c.trim().isEmpty)) continue; // blank line

      final url = cell(row, 'url').trim();
      var title = cell(row, 'title').trim();
      if (title.isEmpty && url.isNotEmpty) title = _hostOf(url);
      final username = cell(row, 'username').trim();
      // Deliberately NOT trimmed: a password may legitimately begin or
      // end with a space. Only rejected if it is entirely blank.
      final secret = cell(row, 'secret');
      if (title.isEmpty || secret.trim().isEmpty) {
        skipped++;
        continue;
      }

      var type = cell(row, 'type').trim().toLowerCase();
      if (!['login', 'note', 'card', 'token', 'wifi'].contains(type)) type = 'login';

      final key = keyOf(type, title, username, secret, url);
      if (!seen.add(key)) {
        duplicates++;
        continue;
      }

      final notes = cell(row, 'notes').trim();
      newEntries.add(VaultEntry(
        id: 'v_${now}_${newEntries.length}',
        type: type,
        title: title,
        username: username.isEmpty ? null : username,
        secret: secret,
        url: url.isEmpty ? null : url,
        notes: notes.isEmpty ? null : notes,
        createdAt: now,
        updatedAt: now,
      ));
    }

    // One read + one write for the whole batch, instead of a full
    // read-modify-write of the encrypted vault per entry.
    await VaultService.insertMany(newEntries);
    return VaultCsvImportResult(
      imported: newEntries.length,
      duplicates: duplicates,
      skipped: skipped,
      headerRecognized: true,
    );
  }
}
