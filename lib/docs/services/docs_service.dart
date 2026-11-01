import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../../reminder/db/reminder_db.dart';
import '../../reminder/models/reminder.dart';
import '../../reminder/services/reminder_service.dart';
import '../db/docs_db.dart';
import '../models/doc_models.dart';
import 'doc_owners.dart';
import 'docs_crypto.dart';

/// নতুন যোগ হতে যাওয়া একটা পাতা (ছবি/PDF) — সেভের সময় এনক্রিপ্ট হয়ে ফাইলে যায়।
class NewDocPage {
  final Uint8List bytes;
  final String name;
  final String mime;
  NewDocPage(this.bytes, this.name, this.mime);
}

/// সেভের সময় একটা পাতার স্লট: হয় আগের পাতা রাখা ([old]), নয়তো নতুন ([fresh])।
/// [fresh] থাকলে আগের পাতাটা (থাকলে) মুছে যায়।
class DocPageEntry {
  final DocPage? old;
  final NewDocPage? fresh;
  final String label;
  DocPageEntry({this.old, this.fresh, required this.label}) : assert(old != null || fresh != null);
}

class DocsService {
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<List<VaultDoc>> list() => DocsDB.all();

  static String newId() => 'd_${DateTime.now().microsecondsSinceEpoch}';

  /// পুরনো পদ্ধতি — ব্যাকআপ রিস্টোর এখনও এটা ব্যবহার করে।
  /// [number] নতুন নম্বর (সাধারণ লেখা) — null হলে আগেরটাই থাকে।
  static Future<void> save(
    VaultDoc doc, {
    String? number,
    List<NewDocPage> added = const [],
    List<DocPage> removed = const [],
  }) async {
    if (number != null) doc.numberEnc = await DocsCrypto.encryptText(number);

    for (final p in removed) {
      await DocsCrypto.deleteFile(p.fileId);
      doc.pages.removeWhere((x) => x.fileId == p.fileId);
    }
    for (final a in added) {
      final id = await DocsCrypto.saveFile(a.bytes);
      doc.pages.add(DocPage(id, a.name, a.mime, a.bytes.length));
    }

    doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _syncReminders(doc);
    await DocsDB.upsert(doc);
    changes.value++;
  }

  /// ফর্ম থেকে সেভ: পাতা ঠিক ক্রমে (সামনে, পেছনে…) থাকে, লেবেলসহ।
  /// [fields] — নম্বর/রোল/রেজি. (null হলে আগেরটাই থাকে)।
  static Future<void> saveEntries(
    VaultDoc doc, {
    Map<String, String>? fields,
    required List<DocPageEntry> entries,
  }) async {
    if (fields != null) {
      doc.numberEnc = await DocsCrypto.encryptText(DocFields.encode(fields));
    }

    final keep = entries.where((e) => e.fresh == null && e.old != null).map((e) => e.old!.fileId).toSet();
    final toDelete = doc.pages.where((p) => !keep.contains(p.fileId)).toList();

    final newPages = <DocPage>[];
    for (final e in entries) {
      if (e.fresh != null) {
        final id = await DocsCrypto.saveFile(e.fresh!.bytes);
        newPages.add(DocPage(id, e.fresh!.name, e.fresh!.mime, e.fresh!.bytes.length, label: e.label));
      } else {
        newPages.add(e.old!.withLabel(e.label));
      }
    }
    doc.pages = newPages;

    doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _syncReminders(doc);
    await DocsDB.upsert(doc);
    // নতুন ডেটা নিরাপদে বসার পরেই আগের ফাইল মোছা।
    for (final p in toDelete) {
      await DocsCrypto.deleteFile(p.fileId);
    }
    changes.value++;
  }

  /// এডিটের পর একটা পাতার ছবি বদলে দেওয়া (জায়গা ও লেবেল একই থাকে)।
  static Future<DocPage> replacePage(VaultDoc doc, DocPage old, Uint8List bytes,
      {String mime = 'image/jpeg'}) async {
    final idx = doc.pages.indexWhere((p) => p.fileId == old.fileId);
    if (idx < 0) throw StateError('পাতাটা আর নেই');
    final id = await DocsCrypto.saveFile(bytes);
    final base = old.name.contains('.') ? old.name.substring(0, old.name.lastIndexOf('.')) : old.name;
    final ext = mime == 'image/png' ? 'png' : 'jpg';
    final fresh = DocPage(id, '$base.$ext', mime, bytes.length, label: old.label);
    doc.pages[idx] = fresh;
    doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await DocsDB.upsert(doc);
    await DocsCrypto.deleteFile(old.fileId);
    changes.value++;
    return fresh;
  }

  /// [oldName]-এর সব ডকুমেন্টের মালিক-নাম [newName] করে। পুরনো ডকুমেন্ট (মালিক ফাঁকা) "নিজের" নামে ধরা হয়।
  /// রিমাইন্ডার/ফাইল/নম্বর ছোঁয় না — শুধু মালিকের নাম। ফেরত: কয়টা ডকুমেন্ট বদলাল।
  static Future<int> renameOwner(String oldName, String newName) async {
    final n = newName.trim();
    if (n.isEmpty) return 0;
    var count = 0;
    for (final d in await DocsDB.all()) {
      final key = d.owner.trim().isEmpty ? DocOwners.self : d.owner.trim();
      if (key != oldName) continue;
      d.owner = n;
      d.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await DocsDB.upsert(d);
      count++;
    }
    if (count > 0) changes.value++;
    return count;
  }

  static Future<void> delete(VaultDoc doc) async {
    for (final p in doc.pages) {
      await DocsCrypto.deleteFile(p.fileId);
    }
    await _deleteReminders(doc.rem);
    await DocsDB.delete(doc.id);
    changes.value++;
  }

  static Future<String> numberOf(VaultDoc d) => DocsCrypto.decryptText(d.numberEnc);

  /// নম্বর / রোল / রেজি. — key → মান।
  static Future<Map<String, String>> fieldsOf(VaultDoc d) async =>
      DocFields.decode(await DocsCrypto.decryptText(d.numberEnc));

  // ── মেয়াদের রিমাইন্ডার: ৯০, ৩০, ৭ দিন আগে ও শেষ দিনে (সকাল ৮টা) ──

  static Future<void> _deleteReminders(List<int> ids) async {
    for (final id in ids) {
      try {
        await ReminderService.delete(id);
      } catch (_) {}
    }
  }

  static Future<void> _syncReminders(VaultDoc d) async {
    await _deleteReminders(d.rem);
    d.rem = [];
    if (d.expiry == null) return;
    final today = dateOnly(DateTime.now());
    final exp = dateOnly(d.expiry!);
    for (final off in const [90, 30, 7, 0]) {
      final day = exp.subtract(Duration(days: off));
      if (day.isBefore(today)) continue;
      final who = d.isMine ? '' : '${d.owner.trim()}-এর ';
      final title = off == 0
          ? '🚨 আজ $who${d.title}-এর মেয়াদ শেষ!'
          : '📄 $who${d.title}-এর মেয়াদ শেষ হতে ${bn(off)} দিন বাকি';
      final r = Reminder(
        title: title,
        note: 'মেয়াদ শেষ: ${formatDateBn(exp)} — নবায়নের প্রস্তুতি নাও',
        kind: 'plan',
        date: day,
        times: ['08:00'],
      );
      r.id = await ReminderDB.insert(r);
      await ReminderService.rearm(r);
      d.rem.add(r.id!);
    }
    ReminderService.changes.value++;
  }

  /// মেয়াদ [days] দিনের মধ্যে শেষ হবে বা শেষ হয়ে গেছে এমন ডকুমেন্ট।
  static Future<List<VaultDoc>> expiringWithin(int days) async {
    final all = await DocsDB.all();
    final out = all.where((d) => d.daysToExpiry != null && d.daysToExpiry! <= days).toList()
      ..sort((a, b) => a.daysToExpiry!.compareTo(b.daysToExpiry!));
    return out;
  }
}
