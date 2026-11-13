import 'package:flutter/material.dart';
import '../cashbook/db/cashbook_db.dart';
import '../cashbook/services/cashbook_backup_service.dart';
import '../docs/db/docs_db.dart';
import '../docs/screens/docs_backup_sheet.dart';
import '../docs/services/docs_backup_service.dart';
import '../family/services/family_backup_service.dart';
import '../jobs/services/job_backup_service.dart';
import '../reminder/models/reminder.dart' show bn;
import '../reminder/services/reminder_backup_service.dart';
import '../screens/vault_backup_sheet.dart';
import '../services/drive_service.dart';
import '../services/safety_net.dart';
import '../services/auto_backup.dart';
import '../services/settings_service.dart';
import '../services/vault_backup_service.dart';
import '../widgets/app_theme.dart';

class _Mod {
  final String id;
  final String emoji;
  final String title;
  final String desc;
  final String file;

  /// true হলে পরিবর্তনের সাথে সাথে নিজে ব্যাকআপ হয় — তাই বয়স দেখে লাল করা হয় না।
  final bool auto;
  final bool replacesOnRestore;

  /// ভল্ট ও ডকুমেন্ট: পাসওয়ার্ড লাগে, তাই নিজস্ব শিট খোলে — Drive থেকে সরাসরি নয়।
  bool get special => id == 'vault' || id == 'docs';
  const _Mod(this.id, this.emoji, this.title, this.desc, this.file,
      {this.auto = false, this.replacesOnRestore = false});
}

/// সব মডিউলের ব্যাকআপ এক জায়গায়: শেষ ব্যাকআপ কবে (Google Drive থেকে দেখা
/// আসল সময়), এখনই ব্যাকআপ, ফিরিয়ে আনা, আর "সব একসাথে"।
class BackupCenterScreen extends StatefulWidget {
  const BackupCenterScreen({super.key});
  @override State<BackupCenterScreen> createState() => _BackupCenterScreenState();
}

class _BackupCenterScreenState extends State<BackupCenterScreen> {
  static const _vaultFile = 'mymanager_vault.mmvault';

  Map<String, DateTime> _times = {};
  int _docCount = 0;
  bool _loading = true;
  String? _busyId; // 'all' বা মডিউলের id
  final Map<String, (String, bool)> _msg = {}; // id → (লেখা, ত্রুটি?)

  List<_Mod> get _mods => [
        _Mod('main', '📁', 'প্রজেক্ট, আইডিয়া ও ফাইল',
            'প্রজেক্ট, টাস্ক, সংযুক্ত ফাইল, ভার্সন', 'mymanager_backup.json',
            auto: SettingsService.getBool('auto_backup_enabled', defaultValue: false),
            ),
        const _Mod('cashbook', '💰', 'ক্যাশবুক', 'খাতা, এন্ট্রি, আবশ্যিক খরচ, দেনা-পাওনা (প্রতি পরিবর্তনে নিজে)',
            'cashbook_backup.json', auto: true),
        const _Mod('jobs', '🧑‍💼', 'চাকরি হাব', 'সার্কুলার, ডকুমেন্ট চেকলিস্ট, টার্গেট (নিজে)',
            JobBackupService.fileName, auto: true),
        const _Mod('family', '👨‍👩‍👧', 'পরিবার', 'সদস্য, তারিখ, বিল, জরুরি তথ্য (নিজে)',
            FamilyBackupService.fileName, auto: true),
        const _Mod('reminders', '⏰', 'রিমাইন্ডার', 'তোমার নিজের বানানো রিমাইন্ডার',
            ReminderBackupService.fileName),
        const _Mod('vault', '🔐', 'ভল্ট (পাসওয়ার্ড)', 'এনক্রিপ্টেড — ব্যাকআপ পাসওয়ার্ড লাগে', _vaultFile),
        if (_docCount > 0)
          const _Mod('docs', '🗂️', 'ডকুমেন্ট ও সনদ',
              'এনক্রিপ্টেড ছবি/PDF — পাসওয়ার্ডসহ ফাইল বানিয়ে Drive/Files-এ রাখো', ''),
      ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final drive = DriveService.instance;
    if (!drive.isSignedIn) {
      try {
        await drive.signInSilently();
      } catch (_) {}
    }
    await _loadTimes();
  }

  Future<void> _loadTimes() async {
    if (mounted) setState(() => _loading = true);
    final t = await DriveService.instance.listBackupTimes();
    int docs = 0;
    try {
      docs = (await DocsDB.all()).length;
    } catch (_) {}
    if (mounted) setState(() { _times = t; _docCount = docs; _loading = false; });
  }

  Future<void> _connect() async {
    setState(() => _loading = true);
    try {
      await DriveService.instance.signIn();
    } catch (_) {}
    await _loadTimes();
  }

  // ───────────────── সময় ও অবস্থা ─────────────────

  DateTime? _lastOf(_Mod m) {
    if (m.id == 'docs') {
      final ms = DocsBackupService.lastBackupMs();
      return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }
    var t = _times[m.file];
    if (m.id == 'vault') {
      final ms = VaultBackupService.lastBackupMs();
      if (ms != 0) {
        final local = DateTime.fromMillisecondsSinceEpoch(ms);
        if (t == null || local.isAfter(t)) t = local;
      }
    }
    return t;
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'এইমাত্র';
    if (d.inHours < 1) return '${bn(d.inMinutes)} মিনিট আগে';
    if (d.inDays < 1) return '${bn(d.inHours)} ঘণ্টা আগে';
    return '${bn(d.inDays)} দিন আগে';
  }

  /// 0 = ভালো, 1 = পুরোনো হচ্ছে, 2 = নেই/অনেক পুরোনো
  int _level(_Mod m) {
    final t = _lastOf(m);
    if (t == null) return 2;
    if (m.auto) return 0;
    final days = DateTime.now().difference(t).inDays;
    return days <= 7 ? 0 : (days <= 30 ? 1 : 2);
  }

  Color _color(int level) => level == 0 ? AppTheme.green : (level == 1 ? AppTheme.yellow : AppTheme.red);

  // ───────────────── কাজ ─────────────────

  void _setMsg(String id, String text, {bool error = false}) {
    if (mounted) setState(() => _msg[id] = (text, error));
  }

  String _driveErr(DriveBackupResult r) {
    switch (r) {
      case DriveBackupResult.notSignedIn:
        return 'Google Drive সংযুক্ত নেই';
      case DriveBackupResult.noBackup:
        return 'Drive-এ ব্যাকআপ নেই';
      default:
        final d = DriveService.instance.lastError;
        return 'ব্যর্থ${d != null ? ' — $d' : ' — ইন্টারনেট দেখো'}';
    }
  }

  /// এক মডিউলের ব্যাকআপ; সফল হলে true। ভল্ট এখানে নয় (পাসওয়ার্ড লাগে)।
  Future<bool> _backupOne(_Mod m) async {
    try {
      DriveBackupResult r;
      switch (m.id) {
        case 'main':
          r = await DriveService.instance.backupDatabase();
          break;
        case 'cashbook':
          r = await CashbookBackupService.backupNow();
          break;
        case 'jobs':
          r = await JobBackupService.backupNow();
          break;
        case 'family':
          r = await FamilyBackupService.backupNow();
          break;
        case 'reminders':
          r = await ReminderBackupService.backupNow();
          break;
        default:
          return false;
      }
      if (r == DriveBackupResult.success) {
        _setMsg(m.id, '✅ ব্যাকআপ হয়েছে');
        return true;
      }
      _setMsg(m.id, _driveErr(r), error: true);
      return false;
    } catch (e) {
      _setMsg(m.id, 'ব্যর্থ: $e', error: true);
      return false;
    }
  }

  Future<void> _backupTap(_Mod m) async {
    if (m.id == 'vault') {
      await showVaultBackupSheet(context);
      await _loadTimes();
      return;
    }
    if (m.id == 'docs') {
      await showDocsBackupSheet(context);
      await _loadTimes();
      return;
    }
    setState(() { _busyId = m.id; _msg.remove(m.id); });
    await _backupOne(m);
    if (mounted) setState(() => _busyId = null);
    await _loadTimes();
  }

  Future<void> _backupAll() async {
    setState(() { _busyId = 'all'; _msg.clear(); });
    var ok = 0, fail = 0;
    for (final m in _mods) {
      if (m.special) continue;
      (await _backupOne(m)) ? ok++ : fail++;
    }
    if (mounted) {
      setState(() => _busyId = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(fail == 0
            ? '✅ ${bn(ok)}টা মডিউলের ব্যাকআপ হয়েছে (ভল্ট আলাদা — পাসওয়ার্ড লাগে)'
            : '${bn(ok)}টা সফল, ${bn(fail)}টা ব্যর্থ — নিচে দেখো'),
      ));
    }
    await _loadTimes();
  }

  Future<void> _restoreTap(_Mod m) async {
    if (m.id == 'vault') {
      await showVaultBackupSheet(context);
      await _loadTimes();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('${m.title} ফিরিয়ে আনবে?'),
        content: Text(m.replacesOnRestore
            ? 'Drive-এর ব্যাকআপ দিয়ে এই মডিউলের বর্তমান সব ডাটা বদলে যাবে। এটা ফেরানো যাবে না!'
            : 'Drive-এর ব্যাকআপ বর্তমান ডাটার সাথে মার্জ হবে — বর্তমান কিছু মুছবে না।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('ফিরিয়ে আনো',
                style: TextStyle(color: m.replacesOnRestore ? AppTheme.red : AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _runRestore(m, null);
  }

  /// [version] null হলে সর্বশেষ ব্যাকআপ; নইলে Drive-এর বাছাই করা পুরনো সংস্করণ।
  Future<void> _runRestore(_Mod m, BackupVersion? version) async {
    setState(() { _busyId = m.id; _msg.remove(m.id); });
    try {
      switch (m.id) {
        case 'main':
          final r = await DriveService.instance.restoreFromDrive(version: version);
          r == DriveBackupResult.success
              ? _setMsg(m.id, _mainRestoreMsg())
              : _setMsg(m.id, _driveErr(r), error: true);
          break;
        case 'cashbook':
          final r = await CashbookBackupService.restoreFromDrive(version: version);
          r
              ? _setMsg(m.id, _cashRestoreMsg())
              : _setMsg(m.id, CashbookBackupService.failReason ?? 'Drive-এ ক্যাশবুকের ব্যাকআপ পাওয়া যায়নি বা সাইন-ইন নেই', error: true);
          break;
        case 'jobs':
          final r = await JobBackupService.restoreFromDrive(version: version);
          r == null
              ? _setMsg(m.id, 'ব্যাকআপ পাওয়া যায়নি বা সাইন-ইন নেই', error: true)
              : _setMsg(m.id, '✅ ${bn(r.circulars)}টা সার্কুলার, ${bn(r.docs)}টা ডকুমেন্ট আপডেট');
          break;
        case 'family':
          final r = await FamilyBackupService.restoreFromDrive(version: version);
          r == null
              ? _setMsg(m.id, 'ব্যাকআপ পাওয়া যায়নি বা সাইন-ইন নেই', error: true)
              : _setMsg(m.id,
                  '✅ ${bn(r.members)} সদস্য, ${bn(r.dates)} তারিখ, ${bn(r.bills)} বিল, ${bn(r.contacts)} জরুরি');
          break;
        case 'reminders':
          final r = await ReminderBackupService.restoreFromDrive(version: version);
          r == null
              ? _setMsg(m.id, 'ব্যাকআপ পাওয়া যায়নি বা সাইন-ইন নেই', error: true)
              : _setMsg(m.id, '✅ ${bn(r)}টা নতুন রিমাইন্ডার ফিরে এসেছে');
          break;
      }
    } catch (e) {
      _setMsg(m.id, 'রিস্টোর ব্যর্থ: $e', error: true);
    }
    if (mounted) setState(() => _busyId = null);
  }

  // ───────────────── পুরনো ভার্সন থেকে ফেরানো ─────────────────

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${bn(t.day)}/${bn(t.month)}/${bn(t.year)} ${bn(two(t.hour))}:${bn(two(t.minute))}';
  }

  String _fmtSize(int b) {
    if (b <= 0) return '—';
    if (b < 1024) return '${bn(b)} বাইট';
    if (b < 1024 * 1024) return '${bn((b / 1024).round())} KB';
    return '${bn((b / 1024 / 1024).toStringAsFixed(1))} MB';
  }

  /// Drive-এ ফাইলের সব সংস্করণ দেখিয়ে একটা বাছতে দেয়; ভেতরে কী আছে দেখিয়ে নিশ্চিত করে তবে ফেরায়।
  /// ভুল করে ফাঁকা ডেটা ব্যাকআপ হয়ে গেলেও আগের সংস্করণ থেকে ডেটা ফিরে পাওয়া যায় (Drive প্রায় ৩০ দিন রাখে)।
  Future<void> _versionsTap(_Mod m) async {
    setState(() { _busyId = m.id; _msg.remove(m.id); });
    final list = await DriveService.instance.listVersions(m.file);
    if (mounted) setState(() => _busyId = null);
    if (!mounted) return;
    if (list.isEmpty) {
      _setMsg(m.id, DriveService.instance.lastError ?? 'Drive-এ কোনো সংস্করণ পাওয়া যায়নি', error: true);
      return;
    }
    final picked = await showModalBottomSheet<BackupVersion>(
      context: context,
      backgroundColor: AppTheme.bg2,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
              child: Text('${m.title} — কোন সংস্করণ ফেরাবে?',
                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text('সাধারণত বড় সাইজের পুরনো সংস্করণেই বেশি ডেটা থাকে। বাছলে ভেতরে কী আছে দেখিয়ে নিশ্চিত করতে বলব।',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final v in list)
                  ListTile(
                    leading: Icon(v.revisionId != null || v.label.contains('সংরক্ষিত') ? Icons.history_rounded : Icons.cloud_done_outlined,
                        color: AppTheme.accent),
                    title: Text(_fmtTime(v.time), style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
                    subtitle: Text('${v.label} · ${_fmtSize(v.size)}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                    onTap: () => Navigator.pop(ctx, v),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;

    setState(() => _busyId = m.id);
    final text = await DriveService.instance.previewVersion(m.file, picked);
    if (mounted) setState(() => _busyId = null);
    if (!mounted) return;
    if (text == null) {
      _setMsg(m.id, DriveService.instance.lastError ?? 'এই সংস্করণ নামানো যায়নি', error: true);
      return;
    }
    final counts = SafetyNet.listCounts(text).entries.where((e) => e.value > 0).toList();
    final summary = counts.isEmpty
        ? 'এই সংস্করণ ফাঁকা — কোনো ডেটা নেই।'
        : counts.map((e) => '${SafetyNet.label(e.key)} ${bn(e.value)}').join(' · ');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('${_fmtTime(picked.time)}-এর সংস্করণ'),
        content: Text(
          'এই সংস্করণে আছে:\n$summary\n\n'
          '${m.replacesOnRestore ? 'ফেরালে এই মডিউলের বর্তমান ডেটা এর দ্বারা বদলে যাবে (বদলানোর আগে বর্তমান ডেটার একটা কপি ফোনে রাখা হবে)।' : 'এটা বর্তমান ডেটার সাথে মার্জ হবে — বর্তমান কিছু মুছবে না।'}',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(
            onPressed: counts.isEmpty ? null : () => Navigator.pop(ctx, true),
            child: const Text('এটাই ফেরাও'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _runRestore(m, picked);
  }

  // ───────────────── UI ─────────────────

  @override
  Widget build(BuildContext context) {
    final drive = DriveService.instance;
    final signedIn = drive.isSignedIn;
    final mods = _mods;
    final needs = signedIn ? mods.where((m) => _level(m) >= 1).length : mods.length;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('ব্যাকআপ কেন্দ্র'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _busyId == null ? _loadTimes : null,
            tooltip: 'রিফ্রেশ',
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.accent,
        onRefresh: _loadTimes,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            _accountCard(signedIn, drive.userEmail),
            const SizedBox(height: 12),
            if (signedIn && SettingsService.getBool('auto_backup_enabled', defaultValue: false)) ...[
              _autoStatusLine(),
              const SizedBox(height: 12),
            ],
            if (signedIn) _summary(needs),
            if (signedIn) const SizedBox(height: 12),
            if (signedIn)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _busyId == null ? _backupAll : null,
                  icon: _busyId == 'all'
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.cloud_upload_rounded),
                  label: const Text('সব একসাথে ব্যাকআপ (ভল্ট বাদে)'),
                ),
              ),
            const SizedBox(height: 14),
            for (final m in mods) _moduleCard(m, signedIn),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'ভল্টের পাসওয়ার্ড হারালে ব্যাকআপ আর খোলা যায় না — পাসওয়ার্ডটা কোথাও লিখে রাখো।',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _mainRestoreMsg() {
    final c = DriveService.instance.lastRestoreCounts;
    if (c == null) return '✅ মার্জ হয়েছে — কিছু মোছা হয়নি';
    return '✅ মার্জ হয়েছে — নতুন যোগ ${bn(c.added)}টি, আপডেট ${bn(c.updated)}টি, আগের মতো ${bn(c.kept)}টি; কিছু মোছা হয়নি';
  }

  String _cashRestoreMsg() {
    final c = CashbookDB.lastImportCounts;
    if (c == null) return '✅ ক্যাশবুক মার্জ হয়েছে — কিছু মোছা হয়নি';
    return '✅ ক্যাশবুক মার্জ হয়েছে — নতুন যোগ ${bn(c.added)}টি, আপডেট ${bn(c.updated)}টি; কিছু মোছা হয়নি';
  }

  Widget _autoStatusLine() {
    final ms = AutoBackup.lastMs;
    final text = ms == 0
        ? '🤖 অটো-ব্যাকআপ চালু — এখনো প্রথম রান হয়নি'
        : '🤖 শেষ অটো-ব্যাকআপ: ${_ago(DateTime.fromMillisecondsSinceEpoch(ms))} — ${AutoBackup.lastDetail}';
    return Text(text,
        style: TextStyle(
            color: AutoBackup.lastOk || ms == 0 ? AppTheme.textMuted : AppTheme.red,
            fontSize: 12));
  }

  Widget _accountCard(bool signedIn, String? email) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: signedIn ? AppTheme.green.withOpacity(0.5) : AppTheme.border),
      ),
      child: Row(children: [
        Icon(signedIn ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            color: signedIn ? AppTheme.green : AppTheme.textMuted, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(signedIn ? 'Google Drive সংযুক্ত' : 'Google Drive সংযুক্ত নেই',
                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(signedIn ? (email ?? '') : 'সংযুক্ত না থাকলে কোনো ব্যাকআপই হয় না',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          ]),
        ),
        if (!signedIn)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
            onPressed: _connect,
            child: const Text('সংযুক্ত করো'),
          ),
      ]),
    );
  }

  Widget _summary(int needs) {
    final ok = needs == 0;
    final c = ok ? AppTheme.green : AppTheme.yellow;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
      child: Text(
        _loading
            ? 'ব্যাকআপের অবস্থা দেখা হচ্ছে...'
            : (ok ? '✅ সব মডিউলের ব্যাকআপ ঠিক আছে' : '⚠️ ${bn(needs)}টা মডিউলের ব্যাকআপ দরকার'),
        style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
    );
  }

  Widget _moduleCard(_Mod m, bool signedIn) {
    final level = _level(m);
    final last = _lastOf(m);
    final color = _color(level);
    final busy = _busyId == m.id || _busyId == 'all';
    final msg = _msg[m.id];
    final status = last == null ? 'কখনো ব্যাকআপ হয়নি' : 'শেষ: ${_ago(last)}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.bg2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 5,
              decoration: BoxDecoration(
                color: signedIn || m.special ? color : AppTheme.textMuted,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(m.emoji, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(m.title,
                          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                    if (busy)
                      const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
                    else
                      Text(signedIn || m.special ? status : '—',
                          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 4),
                  Text(m.desc, style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.35)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy || _busyId != null || (!signedIn && !m.special)
                            ? null
                            : () => _backupTap(m),
                        icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                        label: Text(m.special ? 'ব্যাকআপ / রিস্টোর' : 'ব্যাকআপ নাও'),
                      ),
                    ),
                    if (!m.special) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy || _busyId != null || !signedIn ? null : () => _restoreTap(m),
                          icon: const Icon(Icons.cloud_download_outlined, size: 18),
                          label: const Text('ফিরিয়ে আনো'),
                        ),
                      ),
                    ],
                  ]),
                  if (!m.special && signedIn)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: busy || _busyId != null ? null : () => _versionsTap(m),
                        icon: const Icon(Icons.history_rounded, size: 18),
                        label: const Text('পুরনো ভার্সন থেকে ফেরাও'),
                      ),
                    ),
                  if (msg != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(msg.$1,
                          style: TextStyle(
                              color: msg.$2 ? AppTheme.red : AppTheme.green, fontSize: 12.5, height: 1.4)),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
