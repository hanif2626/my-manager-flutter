import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../models/doc_models.dart';
import '../screens/docs_home_screen.dart';
import 'doc_image_ops.dart';
import 'docs_crypto.dart';

/// শেয়ার + "ব্রাউজার/ওয়েবসাইটে আপলোড"।
///
///  • শেয়ার: ডিক্রিপ্ট করে সাময়িক ফোল্ডারে (share_out) রেখে সিস্টেম শেয়ার শিট খোলে।
///  • আপলোড ট্রে (vault_out): ডিক্রিপ্ট করা কপি এখানে রাখা হয় আর Android-এর
///    DocumentsProvider (VaultDocumentsProvider.kt) এটাকে ফাইল-পিকারে
///    "ডকুমেন্ট ভল্ট" নামে দেখায়। ফাইল [trayTtl]-এর বেশি পুরনো হলে প্রোভাইডার
///    আর দেখায় না ও মুছে ফেলে। (Kotlin-এর TTL_MS-এর সাথে মিল রাখতে হবে)
class DocsExport {
  static const trayTtl = Duration(minutes: 10);
  static final ValueNotifier<int> trayChanges = ValueNotifier(0);

  // ───────── ফোল্ডার ─────────

  static Future<Directory> _sub(String name) async {
    final base = await getTemporaryDirectory();
    final d = Directory('${base.path}/$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Directory> _trayDir() => _sub('vault_out');
  static Future<Directory> _shareDir() => _sub('share_out');

  /// শেয়ারের সাময়িক কপি সাফ। [olderThan] দিলে শুধু ততটা পুরনোগুলো।
  static Future<void> cleanShareTemp({Duration olderThan = Duration.zero}) async {
    try {
      final d = await _shareDir();
      final now = DateTime.now();
      for (final e in d.listSync()) {
        if (e is! File) continue;
        if (olderThan == Duration.zero || now.difference(e.lastModifiedSync()) > olderThan) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ───────── নাম ও টাইপ ─────────

  static String _ext(DocPage p) {
    if (p.isPdf) return 'pdf';
    if (p.mime == 'image/png') return 'png';
    if (p.mime == 'image/webp') return 'webp';
    return 'jpg';
  }

  static String _mimeOfPath(String path) {
    final n = path.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// যেমন: nid_front, ssc, passport — ওয়েবসাইটে আপলোডে সুন্দর ইংরেজি নাম যায়।
  static String _baseName(VaultDoc d, int index) {
    final slug = resolveTemplate(d).slug;
    final label = d.pages[index].label;
    String side = '';
    if (label == kFront) {
      side = 'front';
    } else if (label == kBack) {
      side = 'back';
    } else if (d.pages.length > 1) {
      side = 'page${index + 1}';
    }
    return side.isEmpty ? slug : '${slug}_$side';
  }

  static File _file(Directory dir, String base, String ext, {required bool unique}) {
    var f = File('${dir.path}/$base.$ext');
    if (!unique) return f;
    var n = 2;
    while (f.existsSync()) {
      f = File('${dir.path}/${base}_$n.$ext');
      n++;
    }
    return f;
  }

  // ───────── ফাইল লেখা ─────────

  static Future<List<File>> _writeFiles(VaultDoc d, List<DocPage> pages, Directory dir,
      {required bool unique}) async {
    final out = <File>[];
    for (final p in pages) {
      final idx = d.pages.indexWhere((x) => x.fileId == p.fileId);
      final f = _file(dir, _baseName(d, idx < 0 ? 0 : idx), _ext(p), unique: unique);
      await f.writeAsBytes(await DocsCrypto.readFile(p.fileId), flush: true);
      out.add(f);
    }
    return out;
  }

  static bool hasImages(List<DocPage> pages) => pages.any((p) => !p.isPdf);

  /// সব ছবি-পাতা এক PDF-এ। সামনে+পেছনের ২ পাতা হলে একই A4 পাতায় উপর-নিচে বসে
  /// (সরকারি পোর্টালে এক ফাইলে NID চাইলে কাজে লাগে)।
  static Future<Uint8List> _pdfBytes(VaultDoc d, List<DocPage> pages) async {
    final imgPages = pages.where((p) => !p.isPdf).toList();
    final imgs = <pw.MemoryImage>[];
    for (final p in imgPages) {
      var b = await DocsCrypto.readFile(p.fileId);
      if (p.mime != 'image/jpeg' && p.mime != 'image/png') {
        b = await DocImageOps.render(b, EditParams()); // webp ইত্যাদি → JPEG
      }
      imgs.add(pw.MemoryImage(b));
    }
    if (imgs.isEmpty) throw StateError('PDF বানানোর মতো ছবি নেই');

    final doc = pw.Document(title: d.title);
    final sideBySide = imgPages.length == 2 && imgPages[0].label == kFront && imgPages[1].label == kBack;
    if (sideBySide) {
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (_) => pw.Column(children: [
          pw.Expanded(child: pw.Center(child: pw.Image(imgs[0], fit: pw.BoxFit.contain))),
          pw.SizedBox(height: 16),
          pw.Expanded(child: pw.Center(child: pw.Image(imgs[1], fit: pw.BoxFit.contain))),
        ]),
      ));
    } else {
      for (final im in imgs) {
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          build: (_) => pw.Center(child: pw.Image(im, fit: pw.BoxFit.contain)),
        ));
      }
    }
    return doc.save();
  }

  static Future<File> _writePdf(VaultDoc d, List<DocPage> pages, Directory dir, {required bool unique}) async {
    final f = _file(dir, resolveTemplate(d).slug, 'pdf', unique: unique);
    await f.writeAsBytes(await _pdfBytes(d, pages), flush: true);
    return f;
  }

  // ───────── শেয়ার ─────────

  /// [pages] null হলে ডকুমেন্টের সব পাতা। [asPdf] হলে একটাই PDF।
  static Future<void> share(VaultDoc doc, {List<DocPage>? pages, bool asPdf = false}) async {
    final use = pages ?? doc.pages;
    if (use.isEmpty) throw StateError('শেয়ার করার মতো ফাইল নেই');
    DocsHomeScreen.suppressAutoLock = true;
    try {
      await cleanShareTemp();
      final dir = await _shareDir();
      final files = asPdf
          ? [await _writePdf(doc, use, dir, unique: false)]
          : await _writeFiles(doc, use, dir, unique: false);
      await Share.shareXFiles(
        files.map((f) => XFile(f.path, mimeType: _mimeOfPath(f.path))).toList(),
        subject: doc.title,
      );
    } finally {
      // শেয়ার শিট খুলে যাওয়ার পর অ্যাপ পজ হওয়ার সময়টুকু অটো-লক ঠেকানো।
      Future.delayed(const Duration(seconds: 2), () => DocsHomeScreen.suppressAutoLock = false);
      // ডিক্রিপ্ট করা কপি সাময়িক ফোল্ডারে পড়ে থাকবে না — গ্রহীতা
      // অ্যাপের সময় দিয়ে ২ মিনিট পর সাফ।
      Future.delayed(const Duration(minutes: 2), () => cleanShareTemp());
    }
  }

  // ───────── আপলোড ট্রে ─────────

  /// ফাইলগুলো ট্রেতে রাখে; ফাইল-পিকারে "ডকুমেন্ট ভল্ট" থেকে বাছা যাবে। কতটা ফাইল রাখা হলো তা ফেরত।
  static Future<int> prepareForUpload(VaultDoc doc, {List<DocPage>? pages, bool asPdf = false}) async {
    final use = pages ?? doc.pages;
    if (use.isEmpty) throw StateError('ফাইল নেই');
    await purgeExpiredTray();
    final dir = await _trayDir();
    final files = asPdf
        ? [await _writePdf(doc, use, dir, unique: true)]
        : await _writeFiles(doc, use, dir, unique: true);
    trayChanges.value++;
    return files.length;
  }

  static Future<int> trayCount() async {
    await purgeExpiredTray();
    final d = await _trayDir();
    return d.listSync().whereType<File>().length;
  }

  static Future<void> purgeExpiredTray() async {
    try {
      final d = await _trayDir();
      final now = DateTime.now();
      for (final e in d.listSync()) {
        if (e is File && now.difference(e.lastModifiedSync()) > trayTtl) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<void> clearTray() async {
    try {
      final d = await _trayDir();
      for (final e in d.listSync()) {
        if (e is File) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    trayChanges.value++;
  }
}
