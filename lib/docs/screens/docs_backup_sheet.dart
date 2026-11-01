import 'package:flutter/material.dart';
import '../../family/screens/family_ui.dart';
import 'dart:typed_data';
import '../../reminder/models/reminder.dart' show bn;
import '../../services/drive_service.dart';
import '../../widgets/app_theme.dart';
import '../services/docs_backup_service.dart';
import 'docs_home_screen.dart';

/// পাসওয়ার্ড-সুরক্ষিত ডকুমেন্ট ব্যাকআপ/রিস্টোর শিট।
Future<void> showDocsBackupSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.bg2,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => const _DocsBackupSheet(),
  );
}

class _DocsBackupSheet extends StatefulWidget {
  const _DocsBackupSheet();
  @override State<_DocsBackupSheet> createState() => _DocsBackupSheetState();
}

class _DocsBackupSheetState extends State<_DocsBackupSheet> {
  bool _busy = false;
  String? _msg;
  bool _err = false;

  String _last() {
    final ms = DocsBackupService.lastBackupMs();
    if (ms == 0) return 'এখনো কোনো ব্যাকআপ নেওয়া হয়নি';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inHours < 1) return 'শেষ ব্যাকআপ: এইমাত্র';
    if (d.inDays < 1) return 'শেষ ব্যাকআপ: ${bn(d.inHours)} ঘণ্টা আগে';
    return 'শেষ ব্যাকআপ: ${bn(d.inDays)} দিন আগে';
  }

  Future<T> _external<T>(Future<T> Function() f) async {
    DocsHomeScreen.suppressAutoLock = true;
    try {
      return await f();
    } finally {
      DocsHomeScreen.suppressAutoLock = false;
    }
  }

  Future<String?> _askPassword({required bool confirm, required String title}) {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    bool hide = true;
    String? error;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          backgroundColor: AppTheme.bg2,
          title: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (confirm)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(color: AppTheme.yellow.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: Text('এই পাসওয়ার্ড ভুলে গেলে ব্যাকআপ আর কখনো খোলা যাবে না — রিকভারির উপায় নেই। কোথাও লিখে রাখো।',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.4)),
                ),
              TextField(
                controller: c1,
                obscureText: hide,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'ব্যাকআপ পাসওয়ার্ড',
                  suffixIcon: IconButton(
                    icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                    onPressed: () => setD(() => hide = !hide),
                  ),
                ),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                TextField(controller: c2, obscureText: hide, decoration: const InputDecoration(labelText: 'আবার লেখো')),
              ],
              fError(error),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            TextButton(
              onPressed: () {
                final p = c1.text;
                if (p.isEmpty) {
                  setD(() => error = 'পাসওয়ার্ড দাও');
                  return;
                }
                if (confirm && p.length < DocsBackupService.minPasswordLength) {
                  setD(() => error = 'কমপক্ষে ${DocsBackupService.minPasswordLength} অক্ষর দাও');
                  return;
                }
                if (confirm && p != c2.text) {
                  setD(() => error = 'দুইবারের পাসওয়ার্ড মিলছে না');
                  return;
                }
                Navigator.pop(ctx, p);
              },
              child: Text('ঠিক আছে', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        );
      }),
    );
  }

  void _set(String m, {bool err = false}) {
    if (mounted) setState(() { _msg = m; _err = err; _busy = false; });
  }

  Future<void> _export() async {
    final pw = await _askPassword(confirm: true, title: 'ব্যাকআপের পাসওয়ার্ড ঠিক করো');
    if (pw == null) return;
    setState(() { _busy = true; _msg = 'এনক্রিপ্ট হচ্ছে... (ফাইল বেশি হলে সময় লাগবে)'; _err = false; });
    try {
      final n = await _external(() => DocsBackupService.exportToFile(pw));
      _set('✅ ${bn(n)}টা ডকুমেন্টের এনক্রিপ্টেড ব্যাকআপ তৈরি হয়েছে।\nশেয়ার মেনু থেকে Drive/Files-এ সেভ করো — ফোনেই রাখলে ফোন হারালে কাজে আসবে না।');
    } on DocsBackupException catch (e) {
      _set(e.message, err: true);
    } catch (e) {
      _set('ব্যাকআপ ব্যর্থ: $e', err: true);
    }
  }

  Future<void> _restore() async {
    setState(() { _busy = true; _msg = null; });
    final data = await _external(() async {
      try {
        return await DocsBackupService.pickBackupFile();
      } catch (e) {
        _set('ফাইল পড়া যায়নি: $e', err: true);
        return null;
      }
    });
    if (data == null) {
      if (mounted && _msg == null) setState(() => _busy = false);
      return;
    }
    if (mounted) setState(() => _busy = false);
    await _restoreWithData(data);
  }

  /// [data] = এনক্রিপ্টেড ব্যাকআপ। পাসওয়ার্ড (৩ বার পর্যন্ত) নিয়ে মার্জ-রিস্টোর — বর্তমান কিছু মোছে না।
  Future<void> _restoreWithData(Uint8List data) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final pw = await _askPassword(confirm: false, title: attempt == 0 ? 'ব্যাকআপের পাসওয়ার্ড দাও' : 'আবার চেষ্টা করো');
      if (pw == null) return;
      setState(() { _busy = true; _msg = 'ডিক্রিপ্ট হচ্ছে...'; _err = false; });
      try {
        final r = await DocsBackupService.restore(data, pw);
        _set('✅ রিস্টোর সম্পন্ন: ${bn(r.added)}টা নতুন যোগ হয়েছে'
            '${r.skipped > 0 ? ', ${bn(r.skipped)}টা আগে থেকেই ছিল (বাদ)' : ''}।\nবর্তমান কোনো ডকুমেন্ট মোছা হয়নি।');
        return;
      } on DocsBackupException catch (e) {
        if (e.message.startsWith('পাসওয়ার্ড')) {
          if (mounted) setState(() { _busy = false; _msg = 'পাসওয়ার্ড ভুল'; _err = true; });
        } else {
          _set(e.message, err: true);
          return;
        }
      } catch (e) {
        _set('রিস্টোর ব্যর্থ: $e', err: true);
        return;
      }
    }
    _set('৩ বার ভুল পাসওয়ার্ড — পরে আবার চেষ্টা করো।', err: true);
  }

  // ───────── Google Drive: প্রতি নামের আলাদা ফাইল ─────────

  Future<void> _driveBackup() async {
    final pw = await _askPassword(confirm: true, title: 'ব্যাকআপের পাসওয়ার্ড ঠিক করো');
    if (pw == null) return;
    setState(() { _busy = true; _msg = 'শুরু হচ্ছে… (ফাইল বেশি হলে সময় লাগবে)'; _err = false; });
    try {
      final res = await _external(() => DocsBackupService.backupToDrive(
            pw,
            onProgress: (m) {
              if (mounted) setState(() => _msg = m);
            },
          ));
      final okN = res.where((r) => r.ok).length;
      final lines = res
          .map((r) => r.ok ? '✅ ${r.owner} — ${bn(r.docs)}টা ডকুমেন্ট' : '❌ ${r.owner} — ${r.error ?? 'ব্যর্থ'}')
          .join('\n');
      _set('${okN == res.length ? '✅ সব নামের ব্যাকআপ Drive-এ আলাদা আলাদা ফাইলে রাখা হয়েছে' : '⚠️ ${bn(okN)}/${bn(res.length)} নামের ব্যাকআপ হয়েছে'}\n$lines',
          err: okN != res.length);
    } on DocsBackupException catch (e) {
      _set(e.message, err: true);
    } catch (e) {
      _set('Drive ব্যাকআপ ব্যর্থ: $e', err: true);
    }
  }

  String _fmtT(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${bn(t.day)}/${bn(t.month)}/${bn(t.year)} ${bn(two(t.hour))}:${bn(two(t.minute))}';
  }

  String _fmtS(int b) => b < 1024 * 1024 ? '${bn((b / 1024).round())} KB' : '${bn((b / 1024 / 1024).toStringAsFixed(1))} MB';

  Future<void> _driveRestore() async {
    setState(() { _busy = true; _msg = 'Drive-এর তালিকা আনা হচ্ছে…'; _err = false; });
    final files = await _external(() => DocsBackupService.listDriveBackups());
    if (!mounted) return;
    if (files.isEmpty) {
      _set(DriveService.instance.lastError ?? 'Drive-এ কোনো ডকুমেন্ট ব্যাকআপ পাওয়া যায়নি', err: true);
      return;
    }
    setState(() { _busy = false; _msg = null; });
    final file = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.bg2,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
            child: Text('কার ডকুমেন্ট ফেরাবে?', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          for (final f in files)
            ListTile(
              leading: const Text('👤', style: TextStyle(fontSize: 22)),
              title: Text(f.owner, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
              subtitle: Text('${_fmtT(f.time)} · ${_fmtS(f.size)}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, f.file),
            ),
        ]),
      ),
    );
    if (file == null || !mounted) return;

    // সংস্করণ: এখনকার, Drive-এর পুরনো ভার্সন, আর অ্যাপের রাখা সংরক্ষিত কপি
    setState(() { _busy = true; _msg = 'সংস্করণ খোঁজা হচ্ছে…'; });
    final versions = await _external(() => DriveService.instance.listVersions(file));
    if (!mounted) return;
    setState(() { _busy = false; _msg = null; });
    BackupVersion? chosen;
    if (versions.length > 1) {
      chosen = await showModalBottomSheet<BackupVersion>(
        context: context,
        backgroundColor: AppTheme.bg2,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: ListView(shrinkWrap: true, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 2),
                child: Text('কোন সংস্করণ?', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text('সাধারণত সর্বশেষটাই ঠিক। ভুল করে ফাঁকা/ছোট ব্যাকআপ চলে গেলে বড় সাইজের পুরনোটা বাছো।',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
              ),
              for (final v in versions)
                ListTile(
                  leading: Icon(Icons.history_rounded, color: AppTheme.accent),
                  title: Text(_fmtT(v.time), style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
                  subtitle: Text('${v.label} · ${_fmtS(v.size)}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, v),
                ),
            ]),
          ),
        ),
      );
      if (chosen == null || !mounted) return;
    } else if (versions.isNotEmpty) {
      chosen = versions.first;
    }

    setState(() { _busy = true; _msg = 'Drive থেকে নামানো হচ্ছে…'; _err = false; });
    final data = await _external(() => DriveService.instance.restoreBytes(file, version: chosen));
    if (data == null) {
      _set(DriveService.instance.lastError ?? 'Drive থেকে নামানো যায়নি', err: true);
      return;
    }
    if (mounted) setState(() => _busy = false);
    await _restoreWithData(data);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Row(children: [
            Icon(Icons.enhanced_encryption_rounded, color: AppTheme.accent),
            const SizedBox(width: 10),
            Text('ডকুমেন্ট ব্যাকআপ', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(_last(), style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          const SizedBox(height: 4),
          Text('ডকুমেন্টের ফাইল শুধু এই ফোনের নিরাপদ চাবিতে খোলে। ফোন হারালে বা রিসেট হলে ফাইল ফেরানোর জন্য এই পাসওয়ার্ড-সুরক্ষিত ব্যাকআপ জরুরি।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('এনক্রিপ্টেড ব্যাকআপ ফাইল বানাও'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('ব্যাকআপ ফাইল থেকে রিস্টোর (মার্জ)'),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Icon(Icons.cloud_upload_outlined, color: AppTheme.accent, size: 20),
            const SizedBox(width: 8),
            Text('Google Drive (প্রতি নামের আলাদা ফাইল)',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 4),
          Text('হানিফ, সোয়াদ, শিরিন… প্রত্যেকের ডকুমেন্ট আলাদা এনক্রিপ্টেড ফাইলে — একজনেরটা কখনো আরেকজনেরটা বা অন্য মডিউলের ব্যাকআপ ঢাকে না। '
              'ছোট/ভুল ব্যাকআপে ঢাকার আগে নিজে থেকে আগেরটার কপি থাকে; পুরনো সংস্করণ ফেরানো যায়।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accent, padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: _busy ? null : _driveBackup,
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('Drive-এ ব্যাকআপ রাখো'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: _busy ? null : _driveRestore,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Drive থেকে ফেরাও (মার্জ, পুরনো সংস্করণসহ)'),
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(color: AppTheme.accent)),
          if (_msg != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_err ? AppTheme.red : AppTheme.green).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_msg!, style: TextStyle(color: _err ? AppTheme.red : AppTheme.textPrimary, fontSize: 13, height: 1.45)),
            ),
        ]),
      ),
    );
  }
}
