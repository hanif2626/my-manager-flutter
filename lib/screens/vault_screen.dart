import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart' as otplib;
import '../models/vault_entry.dart';
import '../services/vault_service.dart';
import '../services/vault_csv_service.dart';
import '../services/vault_backup_service.dart';
import 'vault_backup_sheet.dart';
import '../widgets/app_theme.dart';
import 'vault_entry_form_screen.dart';

const _typeIcons = {
  'login': Icons.lock_outline,
  'note': Icons.sticky_note_2_outlined,
  'card': Icons.credit_card,
  'token': Icons.key_outlined,
  'wifi': Icons.wifi,
};
const _typeLabels = {
  'login': 'লগইন', 'note': 'নোট', 'card': 'কার্ড',
  'token': 'টোকেন/API Key', 'wifi': 'WiFi',
};

class VaultScreen extends StatefulWidget {
  /// ফাইল পিকার / শেয়ার / Google সাইন-ইনের মতো বাইরের স্ক্রিন খোলার সময়
  /// true থাকে, যাতে অ্যাপ 'paused' হলেও ভল্ট অটো-লকে বন্ধ হয়ে অপারেশনের
  /// মাঝপথে না কাটে।
  static bool suppressAutoLock = false;

  const VaultScreen({super.key});
  @override State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> with WidgetsBindingObserver {
  List<VaultEntry> _entries = [];
  bool _loading = true;
  String _query = '';
  String _cat = 'login'; // 'login' | 'token' | 'note' | 'card' | 'wifi' | 'all'
  int _changedSinceBackup = 0;
  int _skippedEntries = 0; // ভল্ট পড়ার সময় কয়টা এন্ট্রি ভাঙা পাওয়া গেছে (-1 = পুরো ভল্ট নষ্ট)
  int _lastBackupMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Auto-lock: if the app is backgrounded while the vault is open,
    // kick back out to wherever it was opened from. Coming back in
    // means going through fingerprint/PIN again.
    if (state == AppLifecycleState.paused && mounted && !VaultScreen.suppressAutoLock) {
      // শুধু একটা pop নয় — ডিটেইল শিট/ফর্ম খোলা থাকলে সেটা বন্ধ হয়ে
      // নিচের ভল্ট স্ক্রিন (পাসওয়ার্ডসহ) খোলাই থাকত; তাই রুট পর্যন্ত বন্ধ করো।
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _load() async {
    final list = await VaultService.getAll();
    final skipped = VaultService.lastSkippedCount;
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final last = VaultBackupService.lastBackupMs();
    final changed = list.where((e) => e.updatedAt > last).length;
    if (mounted) setState(() {
      _entries = list; _loading = false;
      _lastBackupMs = last; _changedSinceBackup = changed;
      _skippedEntries = skipped;
    });
  }

  static const _catOrder = ['login', 'token', 'note', 'card', 'wifi'];
  static const _catChipLabels = {
    'login': 'পাসওয়ার্ড', 'token': 'টোকেন/API', 'note': 'নোট',
    'card': 'কার্ড', 'wifi': 'WiFi',
  };

  int _countOf(String t) => _entries.where((e) => e.type == t).length;

  /// ক্যাটাগরি-ভিত্তিক তালিকা: সব একসাথে না দেখিয়ে একটা করে দেখায়।
  List<VaultEntry> get _inCategory =>
      _cat == 'all' ? _entries : _entries.where((e) => e.type == _cat).toList();

  Widget _categoryChips() {
    final cats = _catOrder.where((t) => t == 'login' || _countOf(t) > 0).toList();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          for (final t in cats) _chip(t, '${_catChipLabels[t]} ${_countOf(t)}'),
          _chip('all', 'সব ${_entries.length}'),
        ],
      ),
    );
  }

  Widget _chip(String key, String label) {
    final sel = _cat == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(
            color: sel ? Colors.white : AppTheme.textSecondary,
            fontSize: 12.5, fontWeight: FontWeight.w600)),
        selected: sel,
        showCheckmark: false,
        selectedColor: AppTheme.accent,
        backgroundColor: AppTheme.bg2,
        side: BorderSide(color: sel ? AppTheme.accent : AppTheme.border),
        onSelected: (_) => setState(() => _cat = key),
      ),
    );
  }

  List<VaultEntry> get _filtered {
    final base = _inCategory;
    if (_query.trim().isEmpty) return base;
    final q = _query.toLowerCase();
    return base.where((e) =>
        e.title.toLowerCase().contains(q) ||
        (e.username?.toLowerCase().contains(q) ?? false) ||
        (e.url?.toLowerCase().contains(q) ?? false)).toList();
  }

  Future<void> _openForm({VaultEntry? entry}) async {
    await Navigator.push(context, MaterialPageRoute(
        builder: (_) => VaultEntryFormScreen(entry: entry)));
    await _load();
    // নতুন/বদলানো এন্ট্রি যেন হারিয়ে না যায়: যেই ক্যাটাগরিতে সেভ হলো
    // সেটাতেই চলে যাও।
    if (mounted && _entries.isNotEmpty && _cat != 'all') {
      final latest = _entries.reduce((a, b) => a.updatedAt >= b.updatedAt ? a : b);
      if (latest.type != _cat &&
          DateTime.now().millisecondsSinceEpoch - latest.updatedAt < 60000) {
        setState(() => _cat = latest.type);
      }
    }
  }

  Future<void> _delete(VaultEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('মুছে ফেলবে?'),
        content: Text('"${entry.title}" ভল্ট থেকে স্থায়ীভাবে মুছে যাবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('মুছে ফেলো', style: TextStyle(color: AppTheme.danger))),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await VaultService.delete(entry.id);
      } on VaultCorruptException {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('ভল্টের ডেটা পড়া যাচ্ছে না — মুছে ফেলা হয়নি, ব্যাকআপ থেকে রিস্টোর করো')));
        }
        return;
      }
      _load();
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$label কপি হয়েছে — ৩০ সেকেন্ড পর ক্লিপবোর্ড খালি হয়ে যাবে'),
      backgroundColor: AppTheme.accent, duration: const Duration(seconds: 2),
    ));
    // Best-effort clipboard auto-clear, so a copied secret doesn't sit
    // there indefinitely if something else reads the clipboard later.
    Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  void _showDetail(VaultEntry entry) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _VaultDetailSheet(
        entry: entry,
        onCopy: _copy,
        onEdit: () { Navigator.pop(ctx); _openForm(entry: entry); },
        onDelete: () { Navigator.pop(ctx); _delete(entry); },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('পাসওয়ার্ড ভল্ট'),
        actions: [
          IconButton(
            icon: Icon(Icons.security, color: AppTheme.textSecondary),
            tooltip: 'নিরাপত্তা যাচাই',
            onPressed: () => _showSecurityCheck(),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _exportCsv();
              if (v == 'import') _importCsv();
              if (v == 'backup') _openBackup();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'backup', child: Text('🔐 এনক্রিপ্টেড ব্যাকআপ / রিস্টোর')),
              PopupMenuItem(value: 'export', child: Text('📤 CSV এক্সপোর্ট')),
              PopupMenuItem(value: 'import', child: Text('📥 CSV ইমপোর্ট')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : Column(children: [
              _corruptBanner(),
              _backupBanner(),
              Padding(
                padding: const EdgeInsets.all(14),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'ভল্টে খোঁজো...',
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                    prefixIcon: Icon(Icons.search, color: AppTheme.textMuted, size: 20),
                    filled: true, fillColor: AppTheme.bg2,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: AppTheme.border)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              _categoryChips(),
              const SizedBox(height: 8),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(child: Text(
                        _entries.isEmpty ? 'ভল্ট খালি — নিচের + বাটনে ট্যাপ করে শুরু করো'
                            : (_query.trim().isEmpty && _cat != 'all'
                                ? 'এই ক্যাটাগরিতে কিছু নেই'
                                : 'কিছু পাওয়া যায়নি'),
                        style: TextStyle(color: AppTheme.textMuted)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        itemCount: _filtered.length,
                        itemBuilder: (_, i) {
                          final e = _filtered[i];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              onTap: () => _showDetail(e),
                              leading: Container(
                                width: 40, height: 40,
                                decoration: BoxDecoration(color: AppTheme.bg3,
                                    borderRadius: BorderRadius.circular(10)),
                                child: Icon(_typeIcons[e.type] ?? Icons.lock_outline,
                                    color: AppTheme.textSecondary, size: 20),
                              ),
                              title: Text(e.title, style: TextStyle(
                                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                e.username?.isNotEmpty == true ? e.username! : _typeLabels[e.type] ?? '',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                              ),
                              trailing: e.totpSecret != null && e.totpSecret!.isNotEmpty
                                  ? _MiniTotp(secret: e.totpSecret!)
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
            ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        backgroundColor: AppTheme.accent,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Future<void> _openBackup() async {
    await showVaultBackupSheet(context);
    if (mounted) await _load();
  }

  /// ব্যাকআপ নেই / অনেক দিন আগের / নতুন পরিবর্তন জমেছে → নরম সতর্কবার্তা।
  /// ভল্টের কিছু এন্ট্রি নষ্ট পাওয়া গেলে লাল সতর্ক-ব্যানার — চাপলে ব্যাকআপ/রিস্টোর খোলে।
  Widget _corruptBanner() {
    if (_skippedEntries == 0) return const SizedBox.shrink();
    final text = _skippedEntries == -1
        ? 'ভল্টের ডেটা পড়া যাচ্ছে না — সেভ বন্ধ আছে, ব্যাকআপ থেকে রিস্টোর করো'
        : 'ভল্টের $_skippedEntriesটা এন্ট্রি নষ্ট হয়ে পড়া যায়নি — বাকিগুলো ঠিক আছে, ব্যাকআপ থেকে রিস্টোর করো';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Material(
        color: AppTheme.red.withOpacity(0.13),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openBackup,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.red, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(text,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35))),
              Text('রিস্টোর', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w700, fontSize: 12.5)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _backupBanner() {
    if (_entries.isEmpty) return const SizedBox.shrink();
    final days = _lastBackupMs == 0
        ? 9999
        : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(_lastBackupMs)).inDays;
    final needs = _lastBackupMs == 0 || days >= 30 || (_changedSinceBackup > 0 && days >= 3);
    if (!needs) return const SizedBox.shrink();
    final text = _lastBackupMs == 0
        ? 'ভল্টের কোনো ব্যাকআপ নেই — ফোন হারালে বা রিসেট হলে সব পাসওয়ার্ড চলে যাবে'
        : (_changedSinceBackup > 0
            ? 'শেষ ব্যাকআপের পর $_changedSinceBackupটা এন্ট্রি নতুন/বদলেছে ($days দিন আগে)'
            : 'শেষ ব্যাকআপ $days দিন আগে');
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Material(
        color: AppTheme.yellow.withOpacity(0.13),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openBackup,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(Icons.shield_outlined, color: AppTheme.yellow, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(text,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35))),
              Text('ব্যাকআপ', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w700, fontSize: 12.5)),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _exportCsv() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('CSV এক্সপোর্ট করবে?'),
        content: Text(
          'CSV ফাইলে সব পাসওয়ার্ড প্লেইন টেক্সটে (এনক্রিপশন ছাড়া) লেখা থাকবে — '
          'Chrome বা Bitwarden-এর এক্সপোর্টও ঠিক এভাবেই কাজ করে। শেয়ার করার পর ফাইলটা যেখানে পাঠাচ্ছেন সেটা নিরাপদ কিনা নিশ্চিত হয়ে নিন।',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: Text('বুঝেছি, এক্সপোর্ট করো', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    if (confirm != true) return;
    await VaultCsvService.exportCsv(_entries);
  }

  Future<void> _importCsv() async {
    var progressShown = false;
    void closeProgress() {
      if (progressShown && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        progressShown = false;
      }
    }

    VaultCsvImportResult? result;
    try {
      result = await VaultCsvService.pickAndImport(onFilePicked: () {
        if (!mounted) return;
        progressShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Row(children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('ইমপোর্ট হচ্ছে...')),
            ]),
          ),
        );
      });
    } catch (e) {
      closeProgress();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ইমপোর্ট ব্যর্থ হয়েছে: $e')));
      }
      return;
    }
    closeProgress();
    if (result == null) return; // cancelled
    await _load();
    if (!mounted) return;

    final r = result;
    final String message;
    if (!r.headerRecognized) {
      message = 'ফাইলের প্রথম সারিতে কলামের নাম চেনা যায়নি।\n\n'
          'প্রথম সারিতে অন্তত "name" (বা title/url) আর "password" থাকতে হবে — '
          'যেমন: name,url,username,password,note';
    } else {
      message = '✓ ${r.imported} টা নতুন এন্ট্রি যোগ হয়েছে\n'
          '${r.duplicates > 0 ? '• ${r.duplicates} টা আগে থেকেই ভল্টে ছিল (বাদ)\n' : ''}'
          '${r.skipped > 0 ? '• ${r.skipped} টা বাদ পড়েছে (নাম বা পাসওয়ার্ড খালি — যেমন Passkey)\n' : ''}';
    }
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('CSV ইমপোর্ট'),
        content: Text(message.trim()),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে'))],
      ),
    );
  }

  Future<void> _showSecurityCheck() async {
    final dupes = await VaultService.duplicateSecretCounts();
    final reused = dupes.entries.where((e) => e.value > 1).length;
    final weak = _entries.where((e) {
      if (e.secret.isEmpty) return false;
      final (label, _) = _StrengthProxy.of(e.secret);
      return label == 'দুর্বল';
    }).length;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('নিরাপত্তা যাচাই'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('মোট এন্ট্রি: ${_entries.length}', style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          Text('দুর্বল পাসওয়ার্ড: $weak', style: TextStyle(
              color: weak > 0 ? AppTheme.danger : AppTheme.green)),
          const SizedBox(height: 6),
          Text('পুনরাবৃত্ত পাসওয়ার্ড: $reused', style: TextStyle(
              color: reused > 0 ? AppTheme.danger : AppTheme.green)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ঠিক আছে'))],
      ),
    );
  }
}

/// Tiny helper so the security-check logic can reuse PasswordGenerator's
/// strength scoring without importing it twice under a different name.
class _StrengthProxy {
  static (String, double) of(String s) {
    // Local import kept minimal — see password_generator.dart for the
    // real scoring logic.
    return _score(s);
  }

  static (String, double) _score(String password) {
    if (password.isEmpty) return ('', 0);
    var score = 0;
    if (password.length >= 8) score++;
    if (password.length >= 12) score++;
    if (password.length >= 16) score++;
    if (RegExp(r'[A-Z]').hasMatch(password)) score++;
    if (RegExp(r'[0-9]').hasMatch(password)) score++;
    if (RegExp(r'[!@#\$%^&*()_\-+=?]').hasMatch(password)) score++;
    if (score <= 2) return ('দুর্বল', 0.3);
    if (score <= 4) return ('মাঝারি', 0.6);
    return ('শক্তিশালী', 1.0);
  }
}

/// Small live-updating 6-digit TOTP code shown on the list row, for
/// logins that have 2FA set up.
class _MiniTotp extends StatefulWidget {
  final String secret;
  const _MiniTotp({required this.secret});
  @override State<_MiniTotp> createState() => _MiniTotpState();
}

class _MiniTotpState extends State<_MiniTotp> {
  Timer? _timer;
  String _code = '------';

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  void _tick() {
    try {
      final code = otplib.OTP.generateTOTPCodeString(
          widget.secret, DateTime.now().millisecondsSinceEpoch,
          length: 6, interval: 30, algorithm: otplib.Algorithm.SHA1, isGoogle: true);
      if (mounted) setState(() => _code = code);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Text(_code, style: TextStyle(
      color: AppTheme.accent, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 1));
}

/// Bottom sheet shown when tapping an entry — reveal fields, copy, edit,
/// delete.
class _VaultDetailSheet extends StatefulWidget {
  final VaultEntry entry;
  final void Function(String label, String value) onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _VaultDetailSheet({
    required this.entry, required this.onCopy, required this.onEdit, required this.onDelete,
  });
  @override State<_VaultDetailSheet> createState() => _VaultDetailSheetState();
}

class _VaultDetailSheetState extends State<_VaultDetailSheet> {
  bool _reveal = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_typeIcons[e.type] ?? Icons.lock_outline, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(e.title, style: TextStyle(
              color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700))),
          IconButton(icon: Icon(Icons.edit_outlined, color: AppTheme.textSecondary),
              onPressed: widget.onEdit),
          IconButton(icon: Icon(Icons.delete_outline, color: AppTheme.danger),
              onPressed: widget.onDelete),
        ]),
        const SizedBox(height: 12),
        if (e.username != null && e.username!.isNotEmpty)
          _field('ইউজারনেম', e.username!, copyable: true),
        _field(
          e.type == 'note' ? 'নোট' : e.type == 'card' ? 'কার্ড নম্বর'
              : e.type == 'token' ? 'টোকেন' : e.type == 'wifi' ? 'পাসওয়ার্ড' : 'পাসওয়ার্ড',
          e.secret, copyable: true, maskable: e.type != 'note',
        ),
        if (e.url != null && e.url!.isNotEmpty) _field('URL', e.url!, copyable: true),
        if (e.notes != null && e.notes!.isNotEmpty) _field('নোট', e.notes!, copyable: false),
        if (e.totpSecret != null && e.totpSecret!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('2FA কোড', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          const SizedBox(height: 4),
          _MiniTotp(secret: e.totpSecret!),
        ],
      ]),
    );
  }

  Widget _field(String label, String value, {bool copyable = false, bool maskable = false}) {
    final display = maskable && !_reveal ? '•' * value.length.clamp(6, 20) : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
            const SizedBox(height: 3),
            Text(display, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
          ]),
        ),
        if (maskable)
          IconButton(
            icon: Icon(_reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18, color: AppTheme.textMuted),
            onPressed: () => setState(() => _reveal = !_reveal),
          ),
        if (copyable)
          IconButton(
            icon: Icon(Icons.copy_outlined, size: 18, color: AppTheme.textMuted),
            onPressed: () => widget.onCopy(label, value),
          ),
      ]),
    );
  }
}
