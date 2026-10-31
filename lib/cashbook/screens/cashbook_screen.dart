import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../db/cashbook_db.dart';
import '../models/cashbook_account.dart';
import '../models/cashbook_entry.dart';
import '../models/cashbook_essential.dart';
import '../services/spending_guard.dart';
import 'spending_guard_card.dart';
import '../models/cashbook_debt.dart';
import '../services/cashbook_service.dart';
import '../services/cashbook_backup_service.dart';
import '../services/cashbook_notification_service.dart';
import '../../services/settings_service.dart';
import '../services/cashbook_export_service.dart';
import '../services/cashbook_legacy_import_service.dart';
import '../widgets/bangla_digit_input_formatter.dart';
import 'cashbook_entry_sheet.dart';
import 'cashbook_statement_view.dart';
import 'cashbook_debt_sheet.dart';
import 'cashbook_accounts_screen.dart';
import 'cashbook_voucher_gallery_screen.dart';
import '../../widgets/app_theme.dart';

const _monthNames = ['জানুয়ারি','ফেব্রুয়ারি','মার্চ','এপ্রিল','মে','জুন',
  'জুলাই','আগস্ট','সেপ্টেম্বর','অক্টোবর','নভেম্বর','ডিসেম্বর'];
// Hand-picked short labels for chart axes — some Bangla month names
// (মে, জুন) are shorter than 3 characters, so a blind .substring(0,3)
// crashes on them; this avoids that entirely.
const _monthShort = ['জানু','ফেব্রু','মার্চ','এপ্রিল','মে','জুন',
  'জুলাই','আগস্ট','সেপ্ট','অক্টো','নভে','ডিসে'];
String _monthLabel(String isoDate) {
  final d = DateTime.parse(isoDate);
  return '${_monthNames[d.month - 1]} ${d.year}';
}
String _fmt(double v) {
  final n = v.round();
  final s = n.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final posFromEnd = s.length - i;
    if (i != 0 && posFromEnd % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '৳$buf';
}

class CashbookScreen extends StatefulWidget {
  const CashbookScreen({super.key});
  @override
  State<CashbookScreen> createState() => _CashbookScreenState();
}

class _CashbookScreenState extends State<CashbookScreen> {
  int _tab = 0; // 0 entries, 1 আবশ্যিক খরচ, 2 report, 3 debts
  List<CashbookAccount> _accounts = [];
  List<CashbookEntry> _entries = [];
  List<CashbookEssential> _essentials = [];
  List<CashbookDebt> _debts = [];
  int? _activeAccountId;
  String _filter = 'all';
  DateTimeRange? _dateRange;
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await CashbookDB.processRecurring();
      await CashbookDB.ensureCurrentMonthLedger();
      final accounts = await CashbookDB.getAccounts();
      final entries = await CashbookDB.getEntries();
      final essentials = await CashbookDB.getEssentials();
      final debts = await CashbookDB.getDebts();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _entries = entries;
        _essentials = essentials;
        _debts = debts;
        _activeAccountId ??= CashbookService.lastAccountId;
        if (_activeAccountId == null || !accounts.any((a) => a.id == _activeAccountId)) {
          _activeAccountId = accounts.isNotEmpty ? accounts.first.id : null;
        }
        _loading = false;
        _loadError = null;
      });
      // The 8pm reminder and the always-on backup both re-check
      // themselves every time the Cashbook is opened — fire-and-forget,
      // never allowed to block the UI or the screen from showing.
      unawaited(CashbookNotificationService.refresh()
          .catchError((e) => debugPrint('Cashbook reminder refresh failed: $e')));
      unawaited(CashbookBackupService.backupSilently()
          .catchError((e) => debugPrint('Cashbook backup failed: $e')));
      _maybeAskBatteryExemption();
    } catch (e, st) {
      debugPrint('Cashbook load failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _afterMutation() async {
    await _load();
    CashbookBackupService.backupSilently();
    // Immediately re-check, so saving an entry cancels tonight's
    // remaining reminders right away instead of waiting for the next
    // time the app happens to open or resume.
    unawaited(CashbookNotificationService.refresh()
        .catchError((e) => debugPrint('Cashbook reminder refresh failed: $e')));
  }

  // Asked exactly once, ever — after that we respect whatever the person
  // chose (granted or denied) and never nag about it again.
  static const _askedBatteryKey = 'cashbook_asked_battery_exemption';
  Future<void> _maybeAskBatteryExemption() async {
    if (SettingsService.getBool(_askedBatteryKey, defaultValue: false)) return;
    await SettingsService.setBool(_askedBatteryKey, true);
    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('রাতের রিমাইন্ডার নির্ভরযোগ্য করতে'),
        content: const Text(
          'কিছু ফোনে (Xiaomi, Vivo, Oppo, Samsung) ব্যাটারি সেভার ব্যাকগ্রাউন্ড নোটিফিকেশন বন্ধ করে দেয়। '
          'রাত ৮টার রিমাইন্ডার যেন অ্যাপ বন্ধ থাকলেও আসে, তার জন্য এই অ্যাপটাকে ব্যাটারি অপটিমাইজেশন থেকে বাদ দেওয়া দরকার — '
          'পরের স্ক্রিনে "Allow" চাপুন।',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('পরে')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('ঠিক আছে')),
        ],
      ),
    );
    if (proceed == true) {
      await CashbookNotificationService.requestBatteryExemptionIfNeeded();
    }
  }

  // ── দৈনিক এন্ট্রি রিমাইন্ডার সময় ────────────────────────
  Future<void> _openReminderTimeDialog() async {
    bool enabled = CashbookService.reminderEnabled;
    TimeOfDay time = TimeOfDay(
        hour: CashbookService.reminderHour, minute: CashbookService.reminderMinute);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        return AlertDialog(
          title: const Text('⏰ এন্ট্রি রিমাইন্ডার'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('প্রতিদিন মনে করিয়ে দাও'),
              subtitle: const Text('সেই সময় থেকে রাত ১১:৩০ পর্যন্ত প্রতি ৩০ মিনিটে, '
                  'যতক্ষণ না আজকের একটা এন্ট্রি হয়'),
              value: enabled,
              onChanged: (v) => setSt(() => enabled = v),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: enabled,
              leading: const Icon(Icons.access_time),
              title: const Text('শুরুর সময়'),
              trailing: Text(time.format(ctx), style: const TextStyle(fontWeight: FontWeight.w700)),
              onTap: !enabled
                  ? null
                  : () async {
                      final picked = await showTimePicker(context: ctx, initialTime: time);
                      if (picked != null) setSt(() => time = picked);
                    },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
          ],
        );
      }),
    );

    if (saved == true) {
      await CashbookService.setReminderEnabled(enabled);
      await CashbookService.setReminderTime(time.hour, time.minute);
      await CashbookNotificationService.refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(enabled
              ? '✅ রিমাইন্ডার সেট হয়েছে — ${time.format(context)} থেকে'
              : '🔕 এন্ট্রি রিমাইন্ডার বন্ধ করা হলো'),
        ));
      }
    }
  }

  // ── account ───────────────────────────────────────────
  Future<void> _addAccount() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('নতুন হিসাব'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('যোগ করো')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final id = await CashbookDB.insertAccount(CashbookAccount(
        name: name, icon: '👛', sortOrder: _accounts.length,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      _activeAccountId = id;
      await _afterMutation();
    }
  }

  // ── entries tab helpers ───────────────────────────────
  List<CashbookEntry> get _visibleEntries {
    final q = _searchCtrl.text.trim().toLowerCase();
    final isGlobalSearch = _searchOpen && q.isNotEmpty;
    var list = isGlobalSearch
        ? _entries
        : _entries.where((e) => e.accountId == _activeAccountId).toList();
    if (!isGlobalSearch && _filter != 'all') {
      list = list.where((e) => e.type == _filter).toList();
    }
    if (_dateRange != null) {
      final startStr = _dateRange!.start.toIso8601String().substring(0, 10);
      final endStr = _dateRange!.end.toIso8601String().substring(0, 10);
      list = list.where((e) => e.date.compareTo(startStr) >= 0 && e.date.compareTo(endStr) <= 0).toList();
    }
    if (isGlobalSearch) {
      list = list.where((e) {
        final cat = CashbookService.categoryById(e.category);
        return e.note.toLowerCase().contains(q) ||
            cat.name.toLowerCase().contains(q) ||
            e.amount.toString().contains(q);
      }).toList();
    }
    list.sort((a, b) {
      final d = b.date.compareTo(a.date);
      return d != 0 ? d : (b.id ?? 0).compareTo(a.id ?? 0);
    });
    return list;
  }

  bool get _isGlobalSearch => _searchOpen && _searchCtrl.text.trim().isNotEmpty;

  Future<void> _openEntrySheet({CashbookEntry? entry}) async {
    if (_activeAccountId == null) return;
    final changed = await CashbookEntrySheet.show(context,
        accountId: entry?.accountId ?? _activeAccountId!, entry: entry);
    if (changed == true) await _afterMutation();
  }

  Future<void> _openDebtSheet() async {
    final changed = await CashbookDebtSheet.show(context);
    if (changed == true) await _afterMutation();
  }

  CashbookAccount? get _activeAccount {
    for (final a in _accounts) {
      if (a.id == _activeAccountId) return a;
    }
    return null;
  }

  /// প্রগ্রেস ডায়ালগসহ কাজ চালায়; ব্যর্থ হলে কারণসহ বার্তা দেখিয়ে null ফেরত দেয়।
  Future<T?> _runWithProgress<T>(String failPrefix, Future<T> Function(void Function(String) report) job) async {
    final progress = ValueNotifier<String>('শুরু হচ্ছে…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppTheme.bg2,
          content: Row(children: [
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v, style: TextStyle(color: AppTheme.textPrimary)),
              ),
            ),
          ]),
        ),
      ),
    );
    T? result;
    String? error;
    try {
      result = await job((m) => progress.value = m).timeout(const Duration(minutes: 3));
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // প্রগ্রেস ডায়ালগ বন্ধ
    progress.dispose();
    if (error != null) {
      _toast('$failPrefix: $error');
      return null;
    }
    return result;
  }

  /// শুধু এখন যে হিসাব/মাসে আছো সেটারই PDF — সব মাসের সব এন্ট্রি একসাথে নয় (সেটাই ফোন আটকাত)।
  Future<void> _exportPdf() async {
    final acc = _activeAccount;
    if (acc == null) {
      _toast('আগে যে হিসাব/মাসের PDF চাও সেটা খোলো');
      return;
    }
    final list = _entries.where((e) => e.accountId == acc.id).toList();
    if (list.isEmpty) {
      _toast('"${acc.name}"-এ কোনো এন্ট্রি নেই — PDF বানানোর কিছু নেই');
      return;
    }
    final title = 'ক্যাশবুক — ${acc.name}';
    final pdf = await _runWithProgress<File>(
      'PDF বানানো যায়নি',
      (report) => CashbookExportService.exportPdf(
        title: title,
        subtitle: acc.name,
        entries: list,
        accounts: _accounts,
        onProgress: report,
      ),
    );
    if (pdf == null) return;
    try {
      await CashbookExportService.sharePdf(pdf, title);
    } catch (e) {
      _toast('PDF তৈরি হয়েছে কিন্তু শেয়ার খোলা যায়নি: $e');
    }
  }

  /// শুধু এই মাসের/হিসাবের Excel — ফাইল ও শিটের নামে মাসের নাম থাকে।
  Future<void> _exportExcelMonth() async {
    final acc = _activeAccount;
    if (acc == null) {
      _toast('আগে যে হিসাব/মাসের Excel চাও সেটা খোলো');
      return;
    }
    final list = _entries.where((e) => e.accountId == acc.id).toList();
    if (list.isEmpty) {
      _toast('"${acc.name}"-এ কোনো এন্ট্রি নেই');
      return;
    }
    final file = await _runWithProgress<File>(
      'Excel বানানো যায়নি',
      (report) => CashbookExportService.exportExcelMonth(
        accountName: acc.name,
        entries: list,
        accounts: _accounts,
        onProgress: report,
      ),
    );
    if (file == null) return;
    try {
      await CashbookExportService.shareExcel(file, acc.name);
    } catch (e) {
      _toast('Excel তৈরি হয়েছে কিন্তু শেয়ার খোলা যায়নি: $e');
    }
  }

  /// Export All: সব হিসাব/মাস — আলাদা আলাদা শিটে + শুরুতে সারাংশ শিট।
  Future<void> _exportExcelAll() async {
    if (_entries.isEmpty) {
      _toast('কোনো এন্ট্রি নেই');
      return;
    }
    final file = await _runWithProgress<File>(
      'Excel বানানো যায়নি',
      (report) => CashbookExportService.exportExcelAll(
        entries: _entries,
        accounts: _accounts,
        onProgress: report,
      ),
    );
    if (file == null) return;
    try {
      await CashbookExportService.shareExcel(file, 'সব হিসাব');
    } catch (e) {
      _toast('Excel তৈরি হয়েছে কিন্তু শেয়ার খোলা যায়নি: $e');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _openVoucherGallery() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => CashbookVoucherGalleryScreen(entries: _entries)));
  }

  Future<void> _restoreFromBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ব্যাকআপ থেকে ফিরিয়ে আনবে?'),
        content: const Text(
          'Google Drive-এ রাখা সবশেষ ক্যাশবুক ব্যাকআপ দিয়ে বর্তমান সব ডেটা প্রতিস্থাপিত হবে। '
          'এই ডিভাইসে এখন যা আছে তার সাথে না মিলিয়ে সরাসরি ওভাররাইট হবে — নিশ্চিত হলেই এগোন।',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: Text('ফিরিয়ে আনো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (confirm != true) return;
    if (mounted) {
      showDialog(context: context, barrierDismissible: false,
          builder: (_) => const AlertDialog(content: Row(children: [
            CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('ফিরিয়ে আনা হচ্ছে...')),
          ])));
    }
    final ok = await CashbookBackupService.restoreFromDrive();
    if (mounted) Navigator.pop(context);
    await _afterMutation();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? '✓ ব্যাকআপ থেকে ফিরিয়ে আনা হয়েছে' : 'ফিরিয়ে আনা যায়নি — ${CashbookBackupService.failReason ?? 'Drive-এ ব্যাকআপ নেই বা সাইন-ইন করা নেই'}')));
    }
  }

  Future<void> _importLegacy() async {
    LegacyImportPreview? preview;
    try {
      preview = await CashbookLegacyImportService.pickAndPreview();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('ফাইল পড়তে সমস্যা হয়েছে: $e')));
      }
      return;
    }
    if (preview == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('এটা চেনা যাচ্ছে না — সঠিক Cash Book .db ফাইল বেছে নিন')));
      }
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('পুরনো ব্যাকআপ ইমপোর্ট করবে?'),
        content: Text(
          '${preview!.accountCount}টা হিসাব এবং ${preview.entryCount}টা এন্ট্রি পাওয়া গেছে।\n\n'
          'এগুলো আপনার বর্তমান হিসাবের পাশে নতুন করে যোগ হবে (কিছু মুছে যাবে না)। '
          'সব এন্ট্রি ডিফল্টভাবে "অন্যান্য" ক্যাটাগরিতে থাকবে — পরে চাইলে এডিট করে বদলাতে পারবেন।',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('ইমপোর্ট করো')),
        ],
      ),
    );
    if (confirm != true) return;

    if (mounted) {
      showDialog(
        context: context, barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('ইমপোর্ট হচ্ছে...')),
          ]),
        ),
      );
    }
    try {
      final count = await CashbookLegacyImportService.import(preview.tempPath);
      if (mounted) Navigator.pop(context); // close progress dialog
      await _afterMutation();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('✓ $count টা এন্ট্রি ইমপোর্ট হয়েছে')));
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('ইমপোর্ট ব্যর্থ হয়েছে: $e')));
      }
    }
  }

  // ── build ─────────────────────────────────────────────
  static const _titles = ['ক্যাশবুক', 'আবশ্যিক খরচ', 'রিপোর্ট', 'দেনা-পাওনা'];

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(title: const Text('ক্যাশবুক')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(title: const Text('ক্যাশবুক')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.error_outline, size: 40, color: AppTheme.red),
              const SizedBox(height: 12),
              Text('ক্যাশবুক লোড করতে সমস্যা হয়েছে', style: AppTheme.title(size: 15)),
              const SizedBox(height: 8),
              Text(_loadError!, style: AppTheme.caption(), textAlign: TextAlign.center),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () {
                  setState(() { _loading = true; _loadError = null; });
                  _load();
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent, foregroundColor: Colors.white),
                child: const Text('আবার চেষ্টা করো'),
              ),
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: _tab == 0 ? _accountTitle() : Text(_titles[_tab]),
        actions: [
          if (_tab == 0)
            IconButton(
              icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
              onPressed: () => setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) _searchCtrl.clear();
              }),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'pdf') _exportPdf();
              if (v == 'excel_month') _exportExcelMonth();
              if (v == 'excel_all') _exportExcelAll();
              if (v == 'account') _addAccount();
              if (v == 'import') _importLegacy();
              if (v == 'restore') _restoreFromBackup();
              if (v == 'vouchers') _openVoucherGallery();
              if (v == 'reminder_time') _openReminderTimeDialog();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'pdf', child: Text('📄 এই মাসের PDF${_activeAccount == null ? '' : ' — ${_activeAccount!.name}'}')),
              PopupMenuItem(value: 'excel_month', child: Text('📊 এই মাসের Excel${_activeAccount == null ? '' : ' — ${_activeAccount!.name}'}')),
              const PopupMenuItem(value: 'excel_all', child: Text('📦 Export All — সব হিসাবের Excel')),
              const PopupMenuItem(value: 'account', child: Text('➕ নতুন হিসাব যোগ')),
              const PopupMenuItem(value: 'vouchers', child: Text('🖼️ সব ভাউচার দেখো')),
              const PopupMenuItem(value: 'reminder_time', child: Text('⏰ এন্ট্রি রিমাইন্ডার সময়')),
              const PopupMenuItem(value: 'import', child: Text('📥 পুরনো ব্যাকআপ ইমপোর্ট করো')),
              const PopupMenuItem(value: 'restore', child: Text('☁️ ব্যাকআপ থেকে ফিরিয়ে আনো')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        // খরচ-প্রহরী: আবশ্যিক খরচের টাকা কমে এলে বড় লাল কার্ড (সব ট্যাবের উপরে)
        SpendingGuardCard(onOpenEssentials: () => setState(() => _tab = 1)),
        Expanded(
          child: IndexedStack(index: _tab, children: [
            _buildEntriesTab(),
            _buildEssentialsTab(),
            _buildReportTab(),
            _buildDebtsTab(),
          ]),
        ),
      ]),
      floatingActionButton: _tab == 2 ? null : FloatingActionButton(
        backgroundColor: AppTheme.accent,
        onPressed: () {
          if (_tab == 0) _openEntrySheet();
          if (_tab == 1) _addOrEditEssential();
          if (_tab == 3) _openDebtSheet();
        },
        child: const Icon(Icons.add, color: Colors.white),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: AppTheme.bg2,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'এন্ট্রি'),
          NavigationDestination(icon: Icon(Icons.track_changes_outlined), selectedIcon: Icon(Icons.track_changes), label: 'আবশ্যিক খরচ'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'রিপোর্ট'),
          NavigationDestination(icon: Icon(Icons.handshake_outlined), selectedIcon: Icon(Icons.handshake), label: 'দেনা-পাওনা'),
        ],
      ),
    );
  }

  // ── ENTRIES TAB ───────────────────────────────────────
  /// অ্যাপ বারের শিরোনাম: এখন যে হিসাব/মাসে আছো (যেমন "অক্টোবর ২০২৬ ▾") — ট্যাপ করলে হিসাব বদলানো/নতুন যোগ।
  Widget _accountTitle() {
    final acc = _activeAccount;
    final name = acc == null ? 'ক্যাশবুক' : '${acc.icon}  ${acc.name}';
    return PopupMenuButton<int>(
      tooltip: 'হিসাব/মাস বদলাও',
      color: AppTheme.bg2,
      offset: const Offset(0, 44),
      onSelected: (v) async {
        if (v == -1) {
          _addAccount();
        } else if (v == -2) {
          final picked = await Navigator.push<int>(context,
              MaterialPageRoute(builder: (_) => CashbookAccountsScreen(activeAccountId: _activeAccountId)));
          if (picked != null) {
            setState(() => _activeAccountId = picked);
            CashbookService.setLastAccountId(picked);
          } else {
            _load(); // নাম বদল/মুছে ফেলার পর ব্যালেন্স হালনাগাদ
          }
        } else {
          setState(() => _activeAccountId = v);
          CashbookService.setLastAccountId(v);
        }
      },
      itemBuilder: (_) => [
        for (final a in _accounts)
          if (a.id != null)
            PopupMenuItem<int>(
              value: a.id!,
              child: Text('${a.icon}  ${a.name}',
                  style: TextStyle(
                      fontWeight: a.id == _activeAccountId ? FontWeight.w800 : FontWeight.w500,
                      color: a.id == _activeAccountId ? AppTheme.accent : AppTheme.textPrimary)),
            ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(value: -2, child: Text('📋 সব হিসাব ও ব্যালেন্স')),
        const PopupMenuItem<int>(value: -1, child: Text('➕ নতুন হিসাব/মাস যোগ')),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }

  // ── ENTRIES TAB ───────────────────────────────────────
  // স্টেটমেন্ট-ধাঁচ: সব/দৈনিক/সাপ্তাহিক/মাসিক/বার্ষিক চিপ, জমা-খরচ আলাদা কলাম, প্রতি সারিতে চলতি ব্যালেন্স
  // (বিস্তারিত: cashbook_statement_view.dart)। গ্লোবাল সার্চ চালু থাকলে সব হিসাবের মিলে-যাওয়া এন্ট্রির তালিকা।
  Widget _buildEntriesTab() {
    final own = _entries.where((e) => e.accountId == _activeAccountId).toList();
    return Column(children: [
      if (_searchOpen)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'সব হিসাবে খোঁজো…',
                filled: true,
                fillColor: AppTheme.bg2,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text('গ্লোবাল সার্চ — সব হিসাব একসাথে', style: AppTheme.caption()),
            ),
          ]),
        ),
      Expanded(
        child: _isGlobalSearch
            ? _buildEntriesList(_visibleEntries)
            : CashbookStatementView(
                key: ValueKey(_activeAccountId),
                entries: own,
                onTapEntry: (e) => _openEntrySheet(entry: e),
              ),
      ),
    ]);
  }

  Widget _balancePill(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppTheme.caption(size: 10.5)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: valueColor)),
      ]),
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _filter == value;
    return GestureDetector(
      onTap: () => setState(() => _filter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.textPrimary : AppTheme.bg2,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(label, style: TextStyle(
            fontWeight: FontWeight.w600, fontSize: 12.5,
            color: selected ? AppTheme.bg : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _buildEntriesList(List<CashbookEntry> list) {
    if (list.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🗒️', style: TextStyle(fontSize: 34)),
          const SizedBox(height: 8),
          Text('এখনো কোনো এন্ট্রি নেই', style: AppTheme.body()),
        ]),
      );
    }
    final widgets = <Widget>[];
    String? lastMonth;
    for (final e in list) {
      final m = _monthLabel(e.date);
      if (m != lastMonth) {
        widgets.add(Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(m, style: AppTheme.caption(weight: FontWeight.w700)),
        ));
        lastMonth = m;
      }
      final cat = CashbookService.categoryById(e.category);
      final accIcon = _accounts.firstWhere((a) => a.id == e.accountId,
          orElse: () => CashbookAccount(name: '', icon: '👛', createdAt: 0)).icon;
      widgets.add(ListTile(
        onTap: () => _openEntrySheet(entry: e),
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: AppTheme.bg2, borderRadius: BorderRadius.circular(11)),
          alignment: Alignment.center,
          child: Text(cat.icon, style: const TextStyle(fontSize: 17)),
        ),
        title: Text(e.note, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTheme.title(size: 13.5)),
        subtitle: Text(
          [
            cat.name,
            if (_isGlobalSearch) '$accIcon ${_accounts.firstWhere((a) => a.id == e.accountId, orElse: () => CashbookAccount(name: "", icon: "", createdAt: 0)).name}',
            e.date,
            if (e.voucherImage != null) '📎',
            if (e.recurring) '🔁',
          ].join(' · '),
          style: AppTheme.caption(),
        ),
        trailing: Text(
          '${e.type == 'in' ? '+' : '−'} ${_fmt(e.amount)}',
          style: TextStyle(fontWeight: FontWeight.w700, color: e.type == 'in' ? AppTheme.green : AppTheme.red),
        ),
      ));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 90), children: widgets);
  }

  // ── আবশ্যিক খরচ TAB ───────────────────────────────────
  // যা না করলেই নয় (ভাড়া, কিস্তি, বিল, ফি…) তার তালিকা। "ঠিক আছে" চাপলে খাতায় খরচ লেখা হয়ে
  // ক্যাশ কমে। ক্যাশ বাকি আবশ্যিক খরচের কাছাকাছি গেলে ওপরে লাল সতর্কতা আসে।

  String get _thisMonthKey => CashbookDB.todayIso().substring(0, 7);

  int _dueSort(CashbookEssential a, CashbookEssential b) {
    final x = a.dueDay == 0 ? 99 : a.dueDay;
    final y = b.dueDay == 0 ? 99 : b.dueDay;
    return x.compareTo(y);
  }

  Widget _buildEssentialsTab() {
    final mk = _thisMonthKey;
    final visible = _essentials.where((e) => e.visibleIn(mk)).toList();
    final unpaid = visible.where((e) => !e.paidIn(mk)).toList()..sort(_dueSort);
    final paid = visible.where((e) => e.paidIn(mk)).toList();

    return FutureBuilder<GuardReport>(
      future: SpendingGuard.assess(),
      builder: (context, snap) {
        final r = snap.data;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
          children: [
            Text('আবশ্যিক খরচ', style: AppTheme.title(size: 15)),
            const SizedBox(height: 4),
            Text(
              'যা না করলেই নয় — ভাড়া, কিস্তি, বিল, ফি। মিটে গেলে "ঠিক আছে" চাপো: খাতায় খরচ লেখা হবে, ক্যাশ কমবে।',
              style: AppTheme.caption(),
            ),
            const SizedBox(height: 12),
            if (r != null) _essentialsSummary(r, unpaid.isEmpty && visible.isNotEmpty),
            const SizedBox(height: 14),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Center(
                  child: Text('এখনো কোনো আবশ্যিক খরচ যোগ করা হয়নি\nনিচের বাটনে যোগ করো',
                      textAlign: TextAlign.center, style: AppTheme.body()),
                ),
              ),
            if (unpaid.isNotEmpty) ...[
              Text('বাকি (${unpaid.length}টা)', style: AppTheme.title(size: 13.5)),
              const SizedBox(height: 8),
              for (final e in unpaid) _essentialRow(e, paid: false),
            ],
            if (paid.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('এ মাসে মেটানো হয়েছে (${paid.length}টা)', style: AppTheme.title(size: 13.5)),
              const SizedBox(height: 8),
              for (final e in paid) _essentialRow(e, paid: true),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _addOrEditEssential,
              icon: const Icon(Icons.add),
              label: const Text('নতুন আবশ্যিক খরচ যোগ করো'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                side: BorderSide(color: AppTheme.border, style: BorderStyle.solid),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _essentialsSummary(GuardReport r, bool allDone) {
    final color = r.level == GuardLevel.danger
        ? AppTheme.red
        : (r.level == GuardLevel.near ? AppTheme.yellow : AppTheme.green);
    Widget cell(String label, String value, {Color? c}) => Expanded(
          child: Column(children: [
            Text(value,
                style: AppTheme.title(size: 15, color: c),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(label, style: AppTheme.caption(size: 11)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(children: [
        Row(children: [
          cell('ক্যাশ (ব্যালেন্স)', _fmt(r.balance)),
          cell('বাকি আবশ্যিক', _fmt(r.reserved)),
          cell('নিরাপদ খরচ', _fmt(r.free), c: color),
        ]),
        const SizedBox(height: 10),
        Text(
          r.level == GuardLevel.ok
              ? (allDone ? '✅ এ মাসের সব আবশ্যিক খরচ মেটানো হয়েছে' : '✅ আবশ্যিক খরচ মেটানোর মতো টাকা আছে')
              : (r.level == GuardLevel.danger
                  ? '🚨 টাকা কম খরচ করুন — আবশ্যিক কাজ আগে করুন! ক্যাশ আবশ্যিক খরচের চেয়েও কম।'
                  : '⚠️ টাকা কম খরচ করুন — আবশ্যিক কাজ আগে করুন। ক্যাশ আবশ্যিক খরচের কাছাকাছি।'),
          textAlign: TextAlign.center,
          style: AppTheme.body(size: 13, weight: FontWeight.w700, color: color),
        ),
      ]),
    );
  }

  String _dueLabel(CashbookEssential e) {
    final repeat = e.monthly ? 'প্রতি মাসে' : 'একবার';
    if (e.dueDay <= 0) return '$repeat · তারিখ ঠিক নেই';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(now.year, now.month, e.dueDay);
    final d = due.difference(today).inDays;
    final when = d < 0 ? '${-d} দিন বকেয়া' : (d == 0 ? 'আজই শেষ দিন' : 'আর $d দিন');
    return '$repeat · ${e.dueDay} তারিখ · $when';
  }

  Widget _essentialRow(CashbookEssential e, {required bool paid}) {
    final cat = CashbookService.categoryById(e.category);
    final overdue = !paid &&
        e.dueDay > 0 &&
        DateTime(DateTime.now().year, DateTime.now().month, e.dueDay)
            .isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: overdue ? AppTheme.red.withOpacity(0.6) : AppTheme.border),
      ),
      child: Row(children: [
        // ঠিক আছে / ফেরত নেওয়ার টিক
        IconButton(
          tooltip: paid ? 'ফেরত নাও' : 'ঠিক আছে — মিটিয়েছি',
          iconSize: 30,
          icon: Icon(
            paid ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: paid ? AppTheme.green : AppTheme.accent,
          ),
          onPressed: () => paid ? _undoEssential(e) : _payEssential(e),
        ),
        Expanded(
          child: InkWell(
            onTap: () => _addOrEditEssential(existing: e),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${cat.icon} ${e.title}',
                    style: AppTheme.title(size: 14).copyWith(
                        decoration: paid ? TextDecoration.lineThrough : null,
                        color: paid ? AppTheme.textMuted : null)),
                const SizedBox(height: 3),
                Text(paid ? 'খাতায় খরচ লেখা হয়েছে' : _dueLabel(e),
                    style: AppTheme.caption(color: overdue ? AppTheme.red : null)),
              ]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Text(_fmt(e.amount), style: AppTheme.title(size: 14.5, color: paid ? AppTheme.textMuted : null)),
        ),
      ]),
    );
  }

  Future<void> _payEssential(CashbookEssential e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('মিটিয়েছ?'),
        content: Text('"${e.title}" — ${_fmt(e.amount)} খরচ হিসেবে ক্যাশবুকে লেখা হবে, ক্যাশ থেকে এই টাকা কমবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('হ্যাঁ, ঠিক আছে')),
        ],
      ),
    );
    if (ok != true) return;
    await CashbookDB.setEssentialPaid(e.id!, true);
    await _afterMutation();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('✓ ${e.title} — ${_fmt(e.amount)} খরচ লেখা হয়েছে')));
    }
  }

  Future<void> _undoEssential(CashbookEssential e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ফেরত নেবে?'),
        content: Text('"${e.title}"-এর খরচ-এন্ট্রি খাতা থেকে মুছে যাবে, ক্যাশ আগের মতো হবে। আবার বাকি হিসেবে দেখাবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('হ্যাঁ, ফেরত নাও')),
        ],
      ),
    );
    if (ok != true) return;
    await CashbookDB.setEssentialPaid(e.id!, false);
    await _afterMutation();
  }

  Future<void> _addOrEditEssential({CashbookEssential? existing}) async {
    final categories = CashbookService.getCategories();
    String cat = existing?.category ?? 'bill';
    if (!categories.any((c) => c.id == cat)) cat = categories.first.id;
    bool monthly = existing?.monthly ?? true;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final amountCtrl = TextEditingController(text: existing == null ? '' : existing.amount.toStringAsFixed(0));
    final dayCtrl = TextEditingController(text: (existing?.dueDay ?? 0) > 0 ? '${existing!.dueDay}' : '');

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(existing == null ? 'নতুন আবশ্যিক খরচ' : 'আবশ্যিক খরচ এডিট'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'কীসের খরচ? (যেমন বাসাভাড়া, কিস্তি)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [BanglaDigitInputFormatter()],
                decoration: const InputDecoration(labelText: 'টাকার পরিমাণ (৳)'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: dayCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [BanglaDigitInputFormatter()],
                decoration: const InputDecoration(labelText: 'মাসের কত তারিখের মধ্যে? (ঐচ্ছিক, ১–৩১)'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: cat,
                decoration: const InputDecoration(labelText: 'খাতায় যে ক্যাটাগরিতে লেখা হবে'),
                items: categories.map((c) => DropdownMenuItem(value: c.id, child: Text('${c.icon} ${c.name}'))).toList(),
                onChanged: (v) => setSt(() => cat = v ?? cat),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: monthly,
                title: const Text('প্রতি মাসে হয়'),
                subtitle: Text(monthly ? 'প্রতি মাসে আবার বাকি হয়ে আসবে' : 'একবার মেটালেই শেষ', style: AppTheme.caption()),
                onChanged: (v) => setSt(() => monthly = v),
              ),
            ]),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: Text('মুছো', style: TextStyle(color: AppTheme.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('সেভ করো')),
          ],
        ),
      ),
    );

    if (action == 'delete' && existing != null) {
      await CashbookDB.deleteEssential(existing.id!);
      await _afterMutation();
      return;
    }
    if (action != 'save') return;

    final title = titleCtrl.text.trim();
    final amount = BanglaDigitInputFormatter.parse(amountCtrl.text);
    var day = int.tryParse(dayCtrl.text.trim()) ?? 0;
    if (day < 0 || day > 31) day = 0;
    if (title.isEmpty || amount == null || amount <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('নাম আর টাকার পরিমাণ দিতে হবে')));
      }
      return;
    }
    await CashbookDB.upsertEssential(CashbookEssential(
      id: existing?.id,
      title: title,
      amount: amount,
      dueDay: day,
      category: cat,
      monthly: monthly,
      paidMonth: existing?.paidMonth,
      entryId: existing?.entryId,
      createdAt: existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
    ));
    await _afterMutation();
  }

  // ── REPORT TAB ────────────────────────────────────────
  Widget _buildReportTab() {
    final thisMonth = CashbookDB.todayIso().substring(0, 7);
    final outsThisMonth = _entries.where((e) => e.type == 'out' && e.date.startsWith(thisMonth)).toList();
    final byCat = <String, double>{};
    for (final e in outsThisMonth) {
      byCat[e.category] = (byCat[e.category] ?? 0) + e.amount;
    }
    final rows = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final now = DateTime.now();
    final lastMonthDate = DateTime(now.year, now.month - 1, 1);
    final lastMonthKey = '${lastMonthDate.year}-${lastMonthDate.month.toString().padLeft(2, '0')}';
    final lastMonthTotal = _entries.where((e) => e.type == 'out' && e.date.startsWith(lastMonthKey))
        .fold<double>(0, (s, e) => s + e.amount);
    final thisMonthTotal = outsThisMonth.fold<double>(0, (s, e) => s + e.amount);

    final trend = <MapEntry<String, double>>[];
    for (int i = 5; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      final total = _entries.where((e) => e.type == 'out' && e.date.startsWith(key)).fold<double>(0, (s, e) => s + e.amount);
      trend.add(MapEntry(_monthShort[d.month - 1], total));
    }
    final maxTrend = trend.map((e) => e.value).fold<double>(1, (a, b) => a > b ? a : b);

    String insight;
    if (lastMonthTotal > 0) {
      final diff = ((thisMonthTotal - lastMonthTotal) / lastMonthTotal * 100).round();
      if (diff > 5) insight = '📈 গত মাসের চেয়ে এই মাসে খরচ $diff% বেশি হয়েছে।';
      else if (diff < -5) insight = '📉 গত মাসের চেয়ে এই মাসে খরচ ${diff.abs()}% কম হয়েছে — চমৎকার!';
      else insight = '📊 এই মাসের খরচ গত মাসের কাছাকাছিই আছে।';
    } else {
      insight = '📊 আরও কয়েক মাসের হিসাব হলে তুলনা দেখাতে পারবো।';
    }

    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 30), children: [
      Text('খরচের চিত্র (এই মাস)', style: AppTheme.title(size: 15)),
      const SizedBox(height: 14),
      if (rows.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Text('এই মাসে এখনো কোনো খরচ নেই', style: AppTheme.body()))
      else
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 120, height: 120,
            child: CustomPaint(painter: _PieChartPainter(rows.map((e) => e.value).toList())),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(rows.length, (i) {
                final cat = CashbookService.categoryById(rows[i].key);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(children: [
                    Container(width: 10, height: 10,
                        decoration: BoxDecoration(color: _chartColors[i % _chartColors.length], borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${cat.icon} ${cat.name}', style: AppTheme.body(size: 12.5))),
                    Text(_fmt(rows[i].value), style: AppTheme.title(size: 12.5)),
                  ]),
                );
              }),
            ),
          ),
        ]),
      const SizedBox(height: 22),
      Text('গত ৬ মাসের খরচ', style: AppTheme.title(size: 15)),
      const SizedBox(height: 14),
      SizedBox(
        height: 120,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end,
          children: trend.map((t) {
            final isNow = t == trend.last;
            final h = maxTrend == 0 ? 6.0 : (t.value / maxTrend * 96).clamp(6, 96).toDouble();
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Container(height: h, decoration: BoxDecoration(
                      color: isNow ? AppTheme.red : AppTheme.accent,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(5)))),
                  const SizedBox(height: 6),
                  Text(t.key, style: AppTheme.caption(size: 10)),
                ]),
              ),
            );
          }).toList(),
        ),
      ),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(14)),
        child: Text(insight, style: AppTheme.body(size: 12.5)),
      ),
      const SizedBox(height: 22),
      Text('বছর অনুযায়ী সারাংশ', style: AppTheme.title(size: 15)),
      const SizedBox(height: 12),
      ..._buildYearlySummary(),
    ]);
  }

  List<Widget> _buildYearlySummary() {
    if (_entries.isEmpty) return [Text('এখনো কোনো এন্ট্রি নেই', style: AppTheme.body())];
    final byYear = <String, Map<String, double>>{};
    for (final e in _entries) {
      final y = e.date.substring(0, 4);
      byYear.putIfAbsent(y, () => {'in': 0, 'out': 0});
      byYear[y]![e.type] = byYear[y]![e.type]! + e.amount;
    }
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    return years.map((y) {
      final inSum = byYear[y]!['in']!;
      final outSum = byYear[y]!['out']!;
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: AppTheme.bg2, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: Row(children: [
          Text(y, style: AppTheme.title(size: 14)),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('জমা ${_fmt(inSum)}', style: TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
            Text('খরচ ${_fmt(outSum)}', style: TextStyle(fontSize: 12, color: AppTheme.red)),
          ]),
          const SizedBox(width: 14),
          Text(_fmt(inSum - outSum),
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5,
                  color: (inSum - outSum) >= 0 ? AppTheme.green : AppTheme.red)),
        ]),
      );
    }).toList();
  }

  // ── DEBTS TAB ─────────────────────────────────────────
  Widget _buildDebtsTab() {
    if (_debts.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🤝', style: TextStyle(fontSize: 34)),
          const SizedBox(height: 8),
          Text('কোনো দেনা-পাওনা নেই', style: AppTheme.body()),
        ]),
      );
    }
    final sorted = [..._debts]..sort((a, b) {
      if (a.cleared != b.cleared) return a.cleared ? 1 : -1;
      return b.date.compareTo(a.date);
    });
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
      children: [
        _debtSummary(),
        const SizedBox(height: 16),
        Text('দেনা-পাওনা', style: AppTheme.title(size: 15)),
        const SizedBox(height: 4),
        Text('কাউকে ধার দিয়েছো বা কারো থেকে ধার নিয়েছো — সব একজায়গায়', style: AppTheme.caption()),
        const SizedBox(height: 14),
        for (final d in sorted) _debtCard(d),
      ],
    );
  }

  /// মোট দেনা / মোট পাওনা / নিট — শুধু যেগুলো এখনো মেটানো হয়নি সেগুলোর হিসাব।
  Widget _debtSummary() {
    double oweTotal = 0, getTotal = 0;
    int oweN = 0, getN = 0;
    for (final d in _debts) {
      if (d.cleared) continue;
      if (d.type == 'lend') { getTotal += d.amount; getN++; } else { oweTotal += d.amount; oweN++; }
    }
    final net = getTotal - oweTotal;
    Widget box(String label, double v, int n, Color c) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppTheme.caption()),
              const SizedBox(height: 4),
              Text(_fmt(v), style: TextStyle(color: c, fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('$nজন', style: AppTheme.caption()),
            ]),
          ),
        );
    final netColor = net == 0 ? AppTheme.textSecondary : (net > 0 ? AppTheme.green : AppTheme.red);
    final netLabel = net == 0 ? 'হিসাব সমান' : (net > 0 ? 'নিট আমি পাবো' : 'নিট আমি দেবো');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        Row(children: [
          box('মোট পাওনা (আমি পাবো)', getTotal, getN, AppTheme.green),
          const SizedBox(width: 10),
          box('মোট দেনা (আমি দেবো)', oweTotal, oweN, AppTheme.red),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text(netLabel, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(_fmt(net.abs()), style: TextStyle(color: netColor, fontSize: 18, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _debtCard(CashbookDebt d) {
    return Opacity(
      opacity: d.cleared ? 0.45 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: AppTheme.bg2, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
        child: Row(children: [
          CircleAvatar(backgroundColor: AppTheme.bg3, foregroundColor: AppTheme.textPrimary,
              child: Text(d.name.isNotEmpty ? d.name[0] : '?')),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name, style: AppTheme.title(size: 13.5)),
              Text([d.type == 'lend' ? 'আমি পাবো' : 'আমি দেনা', if (d.note.isNotEmpty) d.note].join(' · '),
                  style: AppTheme.caption(), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          Text(_fmt(d.amount), style: TextStyle(fontWeight: FontWeight.w700, color: d.type == 'lend' ? AppTheme.green : AppTheme.red)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () async {
              final nowCleared = !d.cleared;
              await CashbookDB.setDebtCleared(d.id!, nowCleared);
              await _afterMutation();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(nowCleared
                    ? (d.type == 'lend'
                        ? '✅ ${_fmt(d.amount)} পাওনা আদায় — খাতায় জমা হিসেবে যোগ হয়েছে'
                        : '✅ ${_fmt(d.amount)} দেনা পরিশোধ — খাতায় খরচ হিসেবে যোগ হয়েছে')
                    : 'খাতার ওই এন্ট্রিটা মুছে ফেলা হয়েছে'),
              ));
            },
            child: Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: d.cleared ? AppTheme.green : Colors.transparent,
                border: Border.all(color: d.cleared ? AppTheme.green : AppTheme.border, width: 1.4),
              ),
              child: d.cleared ? const Icon(Icons.check, size: 15, color: Colors.white) : null,
            ),
          ),
        ]),
      ),
    );
  }
}

const _chartColors = [
  Color(0xFF4F46E5), Color(0xFFDC4C4C), Color(0xFFFBBF24), Color(0xFF4ADE80),
  Color(0xFF38BDF8), Color(0xFFF472B6), Color(0xFFA78BFA), Color(0xFFF97316),
];

class _PieChartPainter extends CustomPainter {
  final List<double> values;
  _PieChartPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    double start = -3.14159 / 2;
    for (int i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 3.14159 * 2;
      final paint = Paint()..color = _chartColors[i % _chartColors.length]..style = PaintingStyle.fill;
      canvas.drawArc(rect, start, sweep, true, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) => oldDelegate.values != values;
}
