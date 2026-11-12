import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/vault_backup_service.dart';
import 'vault_screen.dart';
import '../widgets/app_theme.dart';

/// ভল্টের এনক্রিপ্টেড ব্যাকআপ/রিস্টোরের মেনু। ভল্ট স্ক্রিন থেকে খোলে।
Future<void> showVaultBackupSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.bg2,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => const _VaultBackupSheet(),
  );
}

class _VaultBackupSheet extends StatefulWidget {
  const _VaultBackupSheet();
  @override State<_VaultBackupSheet> createState() => _VaultBackupSheetState();
}

class _VaultBackupSheetState extends State<_VaultBackupSheet> {
  bool _busy = false;
  String? _status;
  bool _isError = false;

  /// বাইরের অ্যাক্টিভিটি (শেয়ার, ফাইল পিকার, Google সাইন-ইন) চলার সময়
  /// ভল্টের অটো-লক সাময়িক বন্ধ রাখে; শেষে আবার চালু।
  Future<T> _external<T>(Future<T> Function() op) async {
    VaultScreen.suppressAutoLock = true;
    try {
      return await op();
    } finally {
      VaultScreen.suppressAutoLock = false;
    }
  }

  void _setStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() { _status = msg; _isError = error; _busy = false; });
  }

  String _lastBackupText() {
    final ms = VaultBackupService.lastBackupMs();
    if (ms == 0) return 'এখনো কোনো ব্যাকআপ নেওয়া হয়নি';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'শেষ ব্যাকআপ: এইমাত্র';
    if (d.inHours < 1) return 'শেষ ব্যাকআপ: ${d.inMinutes} মিনিট আগে';
    if (d.inDays < 1) return 'শেষ ব্যাকআপ: ${d.inHours} ঘণ্টা আগে';
    return 'শেষ ব্যাকআপ: ${d.inDays} দিন আগে';
  }

  // ───────────── পাসওয়ার্ড ডায়ালগ ─────────────

  static const _sampleQuestions = [
    'আমার প্রথম স্কুলের নাম কী?',
    'আমার শৈশবের ডাকনাম কী?',
    'আমার প্রথম মোবাইল ফোনের মডেল কী?',
    'আমার সবচেয়ে প্রিয় শিক্ষকের নাম কী?',
  ];

  /// সেট করার সময় (confirm=true): পাসওয়ার্ড + রিকভারি প্রশ্ন-উত্তর।
  /// রিস্টোরের সময় (confirm=false): পাসওয়ার্ড; ফাইলে প্রশ্ন থাকলে "ভুলে গেছি?" বাটন।
  Future<_PwResult?> _askPassword({
    required bool confirm,
    required String title,
    String? recoveryQuestion,
  }) {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    final cq = TextEditingController(text: confirm ? VaultBackupService.lastQuestion() : '');
    final ca = TextEditingController();
    bool hide = true;
    bool useRecovery = false;
    String? error;
    return showDialog<_PwResult>(
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
                  decoration: BoxDecoration(
                    color: AppTheme.yellow.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'এই পাসওয়ার্ড ভুলে গেলে রিকভারি প্রশ্নের উত্তর দিয়ে ফিরে পাওয়া যায় — তবে প্রশ্ন রাখা ঐচ্ছিক। '
                    'প্রশ্ন না রাখলে শুধু এই পাসওয়ার্ড দিয়েই ব্যাকআপ খুলবে।',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.4),
                  ),
                ),
              TextField(
                controller: c1,
                obscureText: hide,
                autofocus: true,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  labelText: confirm ? 'ব্যাকআপ পাসওয়ার্ড' : 'ব্যাকআপের পাসওয়ার্ড',
                  suffixIcon: IconButton(
                    icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                    onPressed: () => setD(() => hide = !hide),
                  ),
                ),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: c2,
                  obscureText: hide,
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: const InputDecoration(labelText: 'আবার লেখো'),
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  value: useRecovery,
                  onChanged: (v) => setD(() => useRecovery = v ?? false),
                  title: Text('রিকভারি প্রশ্ন যোগ করো (ঐচ্ছিক)',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
                if (useRecovery) ...[
                  Text('⚠️ সতর্কতা: এই উত্তর জানলে যে কেউ ব্যাকআপ ফাইল খুলতে পারবে — এমন উত্তর দাও যা কেউ আন্দাজ করতে পারবে না। প্রশ্ন না রাখলে শুধু এই পাসওয়ার্ড দিয়েই ব্যাকআপ খুলবে।',
                      style: TextStyle(color: AppTheme.red, fontSize: 12, height: 1.4)),
                  const SizedBox(height: 8),
                  Text('🔑 পাসওয়ার্ড রিকভারি (পাসওয়ার্ড ভুলে গেলে কাজে লাগবে)',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 0, children: [
                    for (final q in _sampleQuestions)
                      ActionChip(
                        label: Text(q, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setD(() => cq.text = q),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  TextField(
                    controller: cq,
                    style: TextStyle(color: AppTheme.textPrimary),
                    decoration: const InputDecoration(labelText: 'প্রশ্ন (নিজেরটাও লিখতে পারো)'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ca,
                    style: TextStyle(color: AppTheme.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'উত্তর',
                      helperText: 'এমন উত্তর দাও যা অন্য কেউ আন্দাজ করতে পারবে না',
                      helperMaxLines: 2,
                    ),
                  ),
                ],
              ],
              if (!confirm && recoveryQuestion != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, const _PwResult.forgot()),
                    icon: const Icon(Icons.help_outline_rounded, size: 18),
                    label: const Text('পাসওয়ার্ড ভুলে গেছি?'),
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            TextButton(
              onPressed: () {
                final p = c1.text;
                if (confirm && p.length < VaultBackupService.minPasswordLength) {
                  setD(() => error = 'কমপক্ষে ${VaultBackupService.minPasswordLength} অক্ষর দাও');
                  return;
                }
                if (p.isEmpty) {
                  setD(() => error = 'পাসওয়ার্ড দাও');
                  return;
                }
                if (confirm && p != c2.text) {
                  setD(() => error = 'দুইবারের পাসওয়ার্ড মিলছে না');
                  return;
                }
                if (confirm && useRecovery) {
                  if (cq.text.trim().length < 3) {
                    setD(() => error = 'রিকভারি প্রশ্ন লেখো');
                    return;
                  }
                  if (VaultBackupService.normalizeAnswer(ca.text).length < VaultBackupService.minAnswerLength) {
                    setD(() => error = 'উত্তর কমপক্ষে ${VaultBackupService.minAnswerLength} অক্ষরের দাও');
                    return;
                  }
                  if (VaultBackupService.normalizeAnswer(ca.text) == VaultBackupService.normalizeAnswer(p)) {
                    setD(() => error = 'উত্তর আর পাসওয়ার্ড একই রেখো না');
                    return;
                  }
                }
                Navigator.pop(ctx, _PwResult(p, useRecovery ? cq.text.trim() : null, useRecovery ? ca.text : null));
              },
              child: Text('ঠিক আছে', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        );
      }),
    );
  }

  /// প্রশ্নের উত্তর দিয়ে পাসওয়ার্ড ফিরে পাওয়া। পেলে পাসওয়ার্ড, নইলে null।
  Future<String?> _recoverFlow(String text, String question) async {
    final ctrl = TextEditingController();
    String? error;
    bool busy = false;
    final pw = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          backgroundColor: AppTheme.bg2,
          title: Text('পাসওয়ার্ড রিকভারি', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(question, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              enabled: !busy,
              style: TextStyle(color: AppTheme.textPrimary),
              decoration: const InputDecoration(labelText: 'তোমার উত্তর'),
            ),
            if (busy) const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(color: AppTheme.accent),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
            ],
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('বাতিল')),
            TextButton(
              onPressed: busy ? null : () async {
                if (ctrl.text.trim().isEmpty) {
                  setD(() => error = 'উত্তর লেখো');
                  return;
                }
                setD(() { busy = true; error = null; });
                try {
                  final r = await VaultBackupService.recoverPassword(text, ctrl.text);
                  if (ctx.mounted) Navigator.pop(ctx, r);
                } on WrongRecoveryAnswerException {
                  setD(() { busy = false; error = 'উত্তর মেলেনি, আবার চেষ্টা করো'; });
                } on VaultBackupException catch (e) {
                  setD(() { busy = false; error = e.message; });
                } catch (e) {
                  setD(() { busy = false; error = '$e'; });
                }
              },
              child: Text('পাসওয়ার্ড দেখাও', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        );
      }),
    );
    if (pw == null || !mounted) return null;
    // পাওয়া পাসওয়ার্ড দেখাও (কপি করার সুযোগসহ), তারপর এটা দিয়েই রিস্টোর।
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('✅ তোমার ব্যাকআপ পাসওয়ার্ড', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(pw,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          ),
          const SizedBox(height: 8),
          Text('এটা কোথাও নিরাপদে লিখে রাখো। "ঠিক আছে" চাপলে এই পাসওয়ার্ড দিয়েই রিস্টোর শুরু হবে।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
        ]),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: pw)),
            child: const Text('কপি'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('ঠিক আছে', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    return pw;
  }

  // ───────────── অ্যাকশন ─────────────

  Future<void> _exportFile() async {
    final r0 = await _askPassword(confirm: true, title: 'ব্যাকআপের পাসওয়ার্ড ঠিক করো');
    if (r0 == null || r0.pw == null) return;
    final pw = r0.pw!;
    setState(() { _busy = true; _status = 'এনক্রিপ্ট হচ্ছে... (কয়েক সেকেন্ড লাগতে পারে)'; _isError = false; });
    try {
      final n = await _external(() => VaultBackupService.exportToFile(pw, question: r0.question, answer: r0.answer));
      _setStatus('✅ $nটা এন্ট্রির এনক্রিপ্টেড ফাইল তৈরি হয়েছে।\n'
          'শেয়ার মেনু থেকে Drive/Files/অন্য নিরাপদ জায়গায় সেভ করে নাও — ফাইলটা ফোনে একা রাখলে ফোন হারালে কাজে আসবে না।');
    } on VaultBackupException catch (e) {
      _setStatus(e.message, error: true);
    } catch (e) {
      _setStatus('ব্যাকআপ ব্যর্থ: $e', error: true);
    }
  }

  Future<void> _backupDrive() async {
    final r0 = await _askPassword(confirm: true, title: 'ব্যাকআপের পাসওয়ার্ড ঠিক করো');
    if (r0 == null || r0.pw == null) return;
    final pw = r0.pw!;
    setState(() { _busy = true; _status = 'এনক্রিপ্ট করে Drive-এ পাঠানো হচ্ছে...'; _isError = false; });
    try {
      final r = await _external(() => VaultBackupService.backupToDrive(pw, question: r0.question, answer: r0.answer));
      switch (r) {
        case VaultDriveResult.success:
          _setStatus('✅ ভল্ট এনক্রিপ্ট হয়ে Google Drive-এ (MyManager_Backup ফোল্ডারে) সেভ হয়েছে।');
          break;
        case VaultDriveResult.notSignedIn:
          _setStatus('Google Account দিয়ে সাইন ইন করা যায়নি।', error: true);
          break;
        default:
          final d = DriveErr.detail();
          _setStatus('Drive ব্যাকআপ ব্যর্থ।${d != null ? '\n$d' : ' ইন্টারনেট আছে কিনা দেখো।'}', error: true);
      }
    } on VaultBackupException catch (e) {
      _setStatus(e.message, error: true);
    } catch (e) {
      _setStatus('ব্যাকআপ ব্যর্থ: $e', error: true);
    }
  }

  Future<void> _restoreFile() async {
    setState(() { _busy = true; _status = null; });
    String? text;
    try {
      text = await _external(() => VaultBackupService.pickBackupFile());
    } on VaultBackupException catch (e) {
      _setStatus(e.message, error: true);
      return;
    } catch (e) {
      _setStatus('ফাইল পড়া যায়নি: $e', error: true);
      return;
    }
    if (text == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    await _finishRestore(text);
  }

  Future<void> _restoreDrive() async {
    setState(() { _busy = true; _status = 'Drive থেকে নামানো হচ্ছে...'; _isError = false; });
    try {
      final r = await _external(() => VaultBackupService.fetchFromDrive());
      switch (r.status) {
        case VaultDriveResult.success:
          await _finishRestore(r.text!);
          return;
        case VaultDriveResult.notSignedIn:
          _setStatus('Google Account দিয়ে সাইন ইন করা যায়নি।', error: true);
          return;
        case VaultDriveResult.noBackup:
          _setStatus('Drive-এ কোনো ভল্ট ব্যাকআপ নেই।', error: true);
          return;
        case VaultDriveResult.failed:
          _setStatus('Drive থেকে নামানো যায়নি। ইন্টারনেট আছে কিনা দেখো।', error: true);
          return;
      }
    } catch (e) {
      _setStatus('রিস্টোর ব্যর্থ: $e', error: true);
    }
  }

  Future<void> _finishRestore(String text) async {
    if (mounted) setState(() { _busy = false; _status = null; });
    // ভুল পাসওয়ার্ডে আবার চেষ্টার সুযোগ (সর্বোচ্চ ৩ বার)।
    final question = VaultBackupService.readRecoveryQuestion(text);
    for (var attempt = 0; attempt < 3; attempt++) {
      final res = await _askPassword(
          confirm: false,
          title: attempt == 0 ? 'ব্যাকআপের পাসওয়ার্ড দাও' : 'আবার চেষ্টা করো',
          recoveryQuestion: question);
      if (res == null) return;
      String? pw = res.pw;
      if (res.forgot) {
        pw = await _recoverFlow(text, question!);
        if (pw == null) { attempt--; continue; }
      }
      if (pw == null) return;
      if (mounted) setState(() { _busy = true; _status = 'ডিক্রিপ্ট হচ্ছে...'; _isError = false; });
      try {
        final r = await VaultBackupService.restoreFromText(text, pw);
        _setStatus('✅ রিস্টোর সম্পন্ন\n'
            '• ${r.added}টা নতুন যোগ হয়েছে\n'
            '${r.updated > 0 ? '• ${r.updated}টা আপডেট হয়েছে\n' : ''}'
            '${r.skipped > 0 ? '• ${r.skipped}টা আগে থেকেই ছিল (বাদ)\n' : ''}'
            'বর্তমান কোনো এন্ট্রি মোছা হয়নি।');
        return;
      } on WrongBackupPasswordException {
        if (mounted) setState(() { _busy = false; _status = 'পাসওয়ার্ড ভুল'; _isError = true; });
      } on VaultBackupException catch (e) {
        _setStatus(e.message, error: true);
        return;
      } catch (e) {
        _setStatus('রিস্টোর ব্যর্থ: $e', error: true);
        return;
      }
    }
    _setStatus('৩ বার ভুল পাসওয়ার্ড — পরে আবার চেষ্টা করো।'
        '${question != null ? '\n"পাসওয়ার্ড ভুলে গেছি?" চেপে প্রশ্নের উত্তর দিয়ে ফিরে পেতে পারো।' : ''}',
        error: true);
  }

  // ───────────── UI ─────────────

  Widget _tile(IconData icon, String title, String sub, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.bg3,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppTheme.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 0, 8),
        child: Text(t, style: TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(width: 38, height: 4,
                decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Icon(Icons.enhanced_encryption_rounded, color: AppTheme.accent),
            const SizedBox(width: 10),
            Text('ভল্ট ব্যাকআপ (এনক্রিপ্টেড)',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(_lastBackupText(), style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          const SizedBox(height: 4),
          Text('AES-256 + তোমার দেওয়া পাসওয়ার্ড। ফাইল Drive-এ থাকলেও পাসওয়ার্ড ছাড়া কেউ পড়তে পারবে না।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
          _sectionLabel('ব্যাকআপ নাও'),
          _tile(Icons.cloud_upload_outlined, 'Google Drive-এ ব্যাকআপ',
              'MyManager_Backup ফোল্ডারে এনক্রিপ্টেড ফাইল', _backupDrive),
          _tile(Icons.ios_share_rounded, 'ফাইল হিসেবে এক্সপোর্ট',
              '.mmvault ফাইল — যেকোনো জায়গায় সেভ/শেয়ার', _exportFile),
          _sectionLabel('রিস্টোর করো (বর্তমান এন্ট্রি মুছবে না, মার্জ হবে)'),
          _tile(Icons.cloud_download_outlined, 'Google Drive থেকে রিস্টোর',
              'নতুন ফোন বা রিসেটের পর', _restoreDrive),
          _tile(Icons.folder_open_rounded, 'ফাইল থেকে রিস্টোর',
              '.mmvault ফাইল বেছে নাও', _restoreFile),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(color: AppTheme.accent),
            ),
          if (_status != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_isError ? AppTheme.red : AppTheme.green).withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_status!,
                  style: TextStyle(
                      color: _isError ? AppTheme.red : AppTheme.textPrimary,
                      fontSize: 13, height: 1.45)),
            ),
        ]),
      ),
    );
  }
}

/// DriveService.lastError-এর ছোট সহায়ক, যাতে এই ফাইলে সরাসরি drive_service
/// ইমপোর্ট না করেও শেষ এরর মেসেজ দেখানো যায়।
class DriveErr {
  static String? detail() => VaultBackupService.lastDriveError();
}

/// পাসওয়ার্ড ডায়ালগের ফলাফল।
class _PwResult {
  final String? pw;
  final String? question;
  final String? answer;
  final bool forgot;
  const _PwResult(this.pw, this.question, this.answer) : forgot = false;
  const _PwResult.forgot() : pw = null, question = null, answer = null, forgot = true;
}
