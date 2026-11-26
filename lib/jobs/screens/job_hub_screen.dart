import 'package:flutter/material.dart';
import '../../reminder/models/reminder.dart' show bn, dateOnly, formatDateBn;
import '../../widgets/app_theme.dart';
import '../models/job_models.dart';
import '../../services/drive_service.dart' show DriveBackupResult;
import '../radar/radar_pdf_viewer.dart';
import '../services/admit_watcher.dart';
import '../services/app_launcher.dart';
import '../services/job_backup_service.dart';
import '../services/job_service.dart';
import '../radar/radar_tab.dart';

/// সরকারি চাকরির প্রস্তুতির "ম্যানেজার" দিক: সার্কুলার/ডেডলাইন, ডকুমেন্ট,
/// বয়সসীমা ও পরীক্ষার কাউন্টডাউন, সাপ্তাহিক রিভিউ। পড়াশোনার কনটেন্ট
/// (প্রশ্নব্যাংক, মক টেস্ট ইত্যাদি) SmartStudyBD অ্যাপে — এখান থেকে এক ট্যাপে খোলে।
class JobHubScreen extends StatefulWidget {
  /// ভল্ট ট্যাবে যাওয়ার কলব্যাক (পোর্টালের লগইনের জন্য)।
  final VoidCallback onOpenVault;
  /// কোন ট্যাবে খুলবে (০ ওভারভিউ, ১ সার্কুলার, ২ ডকুমেন্ট) — আজকের ম্যানেজার থেকে আসে।
  final int initialTab;

  /// নোটিফিকেশন থেকে এলে: রাডারের এই সার্কুলারটা সামনে/খোলা দেখাবে।
  final String? focusRadarUrl;

  /// নোটিফিকেশন থেকে এলে: সেভ করা এই সার্কুলারটা সরাসরি খুলবে।
  final int? focusCircularId;

  /// 'admit' হলে প্রবেশপত্রের লিংক, নইলে সার্কুলারের শিট খুলবে।
  final String? focusCircularAction;

  const JobHubScreen({
    super.key,
    required this.onOpenVault,
    this.initialTab = 0,
    this.focusRadarUrl,
    this.focusCircularId,
    this.focusCircularAction,
  });
  @override State<JobHubScreen> createState() => _JobHubScreenState();
}

class _JobHubScreenState extends State<JobHubScreen> with SingleTickerProviderStateMixin {
  static const _smartStudyPkg = 'com.hanif.smartstudy';

  late final TabController _tab;
  List<Circular> _circulars = [];
  List<JobDoc> _docs = [];
  bool _loading = true;
  bool _focusHandled = false;
  bool _bkBusy = false;
  String? _bkStatus;
  bool _bkError = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this, initialIndex: widget.initialTab.clamp(0, 3))..addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await AdmitWatcher.reload(); // ব্যাকগ্রাউন্ডে লেখা প্রবেশপত্র-নজরদারির তথ্য তাজা পড়ি
    final c = await JobService.circulars();
    final d = await JobService.docs();
    if (mounted) setState(() { _circulars = c; _docs = d; _loading = false; });
    if (mounted && widget.focusCircularId != null && !_focusHandled) {
      _focusHandled = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _openFocusedCircular());
    }
  }

  Future<void> _openFocusedCircular() async {
    if (!mounted) return;
    Circular? found;
    for (final c in _circulars) {
      if (c.id == widget.focusCircularId) {
        found = c;
        break;
      }
    }
    if (found == null) return;
    _tab.animateTo(2);
    if (widget.focusCircularAction == 'admit' &&
        AdmitWatcher.info(found.id)?['found'] == true) {
      await _openAdmit(found);
    } else {
      await _circularSheet(existing: found);
    }
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ───────────────────────── সাধারণ সহায়ক ─────────────────────────

  Color _urgencyColor(int days) {
    if (days < 0) return AppTheme.textMuted;
    if (days <= 3) return AppTheme.red;
    if (days <= 7) return AppTheme.yellow;
    return AppTheme.green;
  }

  String _daysLabel(int days) {
    if (days < 0) return 'শেষ হয়ে গেছে';
    if (days == 0) return 'আজই শেষ';
    return 'আর ${bn(days)} দিন';
  }

  Future<DateTime?> _pickDate(DateTime? initial, {DateTime? first}) {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: initial ?? now,
      firstDate: first ?? DateTime(now.year - 1),
      lastDate: DateTime(now.year + 30),
    );
  }

  Widget _card({required Widget child, VoidCallback? onTap, EdgeInsets? padding}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: padding ?? const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.border),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, Color color, {VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      ),
    );
  }

  // ───────────────────────── বিল্ড ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('চাকরি হাব'),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppTheme.accent,
          labelColor: AppTheme.accent,
          unselectedLabelColor: AppTheme.textMuted,
          tabs: const [Tab(text: 'রাডার'), Tab(text: 'ওভারভিউ'), Tab(text: 'সার্কুলার'), Tab(text: 'ডকুমেন্ট')],
        ),
      ),
      // ট্যাব: ০ রাডার · ১ ওভারভিউ · ২ সার্কুলার · ৩ ডকুমেন্ট (রাডার সবার আগে)
      floatingActionButton: (_tab.index == 0 || _tab.index == 1)
          ? null
          : FloatingActionButton(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              onPressed: _tab.index == 2 ? () => _circularSheet() : _addDoc,
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : TabBarView(
              controller: _tab,
              children: [
                RadarTab(onSaved: _load, focusUrl: widget.focusRadarUrl),
                _overview(),
                _circularTab(),
                _docTab()
              ],
            ),
    );
  }

  // ───────────────────────── ওভারভিউ ─────────────────────────

  Widget _overview() {
    final ageOut = JobService.ageOut;
    final examDate = JobService.examDate;
    final examName = JobService.examName;
    final urgent = _circulars.where((c) => c.needsAction).take(3).toList();
    final docsDone = _docs.where((d) => d.done).length;
    final weekly = JobService.weeklyOn;

    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 90), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _countdownCard(
          icon: '⏳',
          title: 'বয়সসীমা',
          date: ageOut,
          emptyHint: 'শেষ তারিখ সেট করো',
          onTap: _editAgeOut,
          onClear: ageOut == null ? null : () async { await JobService.setAgeOut(null); _load(); },
          useMonths: true,
        )),
        const SizedBox(width: 10),
        Expanded(child: _countdownCard(
          icon: '🎯',
          title: examName.isEmpty ? 'টার্গেট পরীক্ষা' : examName,
          date: examDate,
          emptyHint: 'পরীক্ষা সেট করো',
          onTap: _editExam,
          onClear: examDate == null ? null : () async { await JobService.setExam(examName, null); _load(); },
        )),
      ]),
      _targetCard(),
      if (urgent.isNotEmpty) ...[
        _sectionTitle('জরুরি ডেডলাইন'),
        for (final c in urgent) _urgentTile(c),
      ] else
        _card(
          onTap: () { _tab.animateTo(2); },
          child: Row(children: [
            Icon(Icons.campaign_outlined, color: AppTheme.textMuted),
            const SizedBox(width: 10),
            Expanded(child: Text('কোনো খোলা সার্কুলার ট্র্যাক করা নেই — যোগ করলে ডেডলাইনের আগে নিজে মনে করিয়ে দেব',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4))),
          ]),
        ),
      _sectionTitle('ডকুমেন্ট প্রস্তুতি'),
      _card(
        onTap: () { _tab.animateTo(3); },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('${bn(docsDone)}/${bn(_docs.length)} টা প্রস্তুত',
                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            const Spacer(),
            Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _docs.isEmpty ? 0 : docsDone / _docs.length,
              minHeight: 6,
              backgroundColor: AppTheme.bg3,
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.green),
            ),
          ),
        ]),
      ),
      _sectionTitle('দ্রুত কাজ'),
      _actionTile(Icons.school_rounded, 'SmartStudyBD খোলো',
          'প্রশ্নব্যাংক, মক টেস্ট, ভাইভা — পড়াশোনা ওখানে', _openSmartStudy),
      _actionTile(Icons.lock_outline_rounded, 'পোর্টালের লগইন (ভল্ট)',
          'BPSC, Teletalk, বোর্ডের পোর্টালের পাসওয়ার্ড এখানে রাখো', () {
        Navigator.pop(context);
        widget.onOpenVault();
      }),
      _card(
        child: Row(children: [
          Icon(Icons.event_repeat_rounded, color: AppTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('সাপ্তাহিক রিভিউ',
                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('প্রতি শুক্রবার রাত ৮টায়: কী পড়লাম, কী বাকি, পরের সপ্তাহের লক্ষ্য',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.35)),
            ]),
          ),
          Switch(
            value: weekly,
            activeColor: AppTheme.accent,
            onChanged: (v) async {
              await JobService.setWeekly(v);
              if (mounted) setState(() {});
            },
          ),
        ]),
      ),
      _sectionTitle('ব্যাকআপ'),
      _backupCard(),
    ]);
  }

  Widget _backupCard() {
    final last = JobBackupService.lastBackupAt;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.cloud_done_outlined, color: AppTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'সার্কুলার, ডকুমেন্ট ও টার্গেট Google Drive-এ নিজে সেভ হয় (সাইন-ইন থাকলে)।'
              '${last != null ? '\nএই সেশনে শেষ ব্যাকআপ: ${last.hour}:${last.minute.toString().padLeft(2, '0')}' : ''}',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.4),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _bkBusy ? null : _backupNow,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('এখনই ব্যাকআপ'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _bkBusy ? null : _restoreBackup,
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('ফিরিয়ে আনো'),
            ),
          ),
        ]),
        if (_bkBusy)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(color: AppTheme.accent),
          ),
        if (_bkStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_bkStatus!,
                style: TextStyle(
                    color: _bkError ? AppTheme.red : AppTheme.green,
                    fontSize: 12.5, height: 1.4)),
          ),
      ]),
    );
  }

  Future<void> _backupNow() async {
    setState(() { _bkBusy = true; _bkStatus = null; });
    String msg;
    var err = false;
    try {
      final r = await JobBackupService.backupNow();
      switch (r) {
        case DriveBackupResult.success:
          msg = '✅ Google Drive-এ ব্যাকআপ হয়েছে';
          break;
        case DriveBackupResult.notSignedIn:
          msg = 'Google Account দিয়ে সাইন ইন করা যায়নি';
          err = true;
          break;
        default:
          msg = 'ব্যাকআপ ব্যর্থ — ইন্টারনেট আছে কিনা দেখো';
          err = true;
      }
    } catch (e) {
      msg = 'ব্যাকআপ ব্যর্থ: $e';
      err = true;
    }
    if (mounted) setState(() { _bkBusy = false; _bkStatus = msg; _bkError = err; });
  }

  Future<void> _restoreBackup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('Drive থেকে ফিরিয়ে আনবে?'),
        content: const Text('ব্যাকআপের সার্কুলার ও ডকুমেন্ট বর্তমান ডাটার সাথে মার্জ হবে — বর্তমান কিছু মুছবে না। সার্কুলারের রিমাইন্ডার নতুন করে বসবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('ফিরিয়ে আনো', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() { _bkBusy = true; _bkStatus = null; });
    String msg;
    var err = false;
    try {
      final r = await JobBackupService.restoreFromDrive();
      if (r == null) {
        msg = 'Drive-এ চাকরি হাবের ব্যাকআপ পাওয়া যায়নি, বা সাইন-ইন হয়নি';
        err = true;
      } else {
        msg = '✅ ফিরে এসেছে: ${bn(r.circulars)}টা সার্কুলার, ${bn(r.docs)}টা ডকুমেন্ট আপডেট';
      }
    } catch (e) {
      msg = 'রিস্টোর ব্যর্থ: $e';
      err = true;
    }
    await _load();
    if (mounted) setState(() { _bkBusy = false; _bkStatus = msg; _bkError = err; });
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 0, 8),
        child: Text(t,
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w700)),
      );

  Widget _countdownCard({
    required String icon,
    required String title,
    required DateTime? date,
    required String emptyHint,
    required VoidCallback onTap,
    VoidCallback? onClear,
    bool useMonths = false,
  }) {
    final days = date == null ? null : dateOnly(date).difference(dateOnly(DateTime.now())).inDays;
    final color = days == null ? AppTheme.textMuted : _urgencyColor(days);
    String big;
    String small;
    if (days == null) {
      big = '—';
      small = emptyHint;
    } else if (days < 0) {
      big = 'শেষ';
      small = formatDateBn(date!);
    } else {
      big = bn(days);
      small = useMonths && days >= 60
          ? 'দিন (≈ ${bn(days ~/ 30)} মাস) · ${formatDateBn(date!)}'
          : 'দিন বাকি · ${formatDateBn(date!)}';
    }
    return _card(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(icon, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          if (onClear != null)
            GestureDetector(
              onTap: onClear,
              child: Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
            ),
        ]),
        const SizedBox(height: 8),
        Text(big, style: TextStyle(color: color, fontSize: 30, fontWeight: FontWeight.w800, height: 1)),
        const SizedBox(height: 4),
        Text(small, style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.3)),
      ]),
    );
  }

  Widget _targetCard() {
    final post = JobService.targetPost;
    final grade = JobService.targetGrade;
    final salary = JobService.targetSalary;
    final empty = post.isEmpty && grade.isEmpty && salary.isEmpty;
    return _card(
      onTap: _editTarget,
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.14),
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(Icons.workspace_premium_rounded, color: AppTheme.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: empty
              ? Text('টার্গেট পদ, গ্রেড ও বেতন সেট করো — লক্ষ্য চোখের সামনে থাকবে',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(post.isEmpty ? 'টার্গেট পদ' : post,
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text([
                    if (grade.isNotEmpty) 'গ্রেড $grade',
                    if (salary.isNotEmpty) 'মূল বেতন $salary',
                  ].join(' · '),
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
                ]),
        ),
        Icon(Icons.edit_outlined, size: 18, color: AppTheme.textMuted),
      ]),
    );
  }

  Widget _urgentTile(Circular c) {
    final d = c.daysLeft ?? 0;
    return _card(
      onTap: () { _tab.animateTo(2); },
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
            if (c.post.isNotEmpty || c.org.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text([c.org, c.post].where((e) => e.isNotEmpty).join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        _chip(_daysLabel(d), _urgencyColor(d)),
      ]),
    );
  }

  Widget _actionTile(IconData icon, String title, String sub, VoidCallback onTap) {
    return _card(
      onTap: onTap,
      child: Row(children: [
        Icon(icon, color: AppTheme.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(sub, style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.35)),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
      ]),
    );
  }

  Future<void> _openSmartStudy() async {
    final ok = await AppLauncher.launchApp(_smartStudyPkg);
    if (!ok) _snack('SmartStudyBD অ্যাপ এই ফোনে পাওয়া যায়নি');
  }

  // ── ওভারভিউয়ের এডিট ডায়ালগ ──

  Future<void> _editAgeOut() async {
    final d = await _pickDate(JobService.ageOut, first: DateTime(2000));
    if (d == null) return;
    await JobService.setAgeOut(d);
    _load();
  }

  Future<void> _editExam() async {
    final nameCtrl = TextEditingController(text: JobService.examName);
    DateTime? date = JobService.examDate;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          backgroundColor: AppTheme.bg2,
          title: const Text('টার্গেট পরীক্ষা'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'পরীক্ষার নাম (যেমন: BCS প্রিলি)'),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              icon: const Icon(Icons.event, size: 18),
              label: Text(date == null ? 'তারিখ বাছো' : formatDateBn(date!)),
              onPressed: () async {
                final d = await _pickDate(date);
                if (d != null) setD(() => date = d);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),
                child: Text('সংরক্ষণ', style: TextStyle(color: AppTheme.accent))),
          ],
        );
      }),
    );
    if (saved == true) {
      await JobService.setExam(nameCtrl.text.trim(), date);
      _load();
    }
  }

  Future<void> _editTarget() async {
    final post = TextEditingController(text: JobService.targetPost);
    final grade = TextEditingController(text: JobService.targetGrade);
    final salary = TextEditingController(text: JobService.targetSalary);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('টার্গেট পদ'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: post, decoration: const InputDecoration(labelText: 'পদ (যেমন: সহকারী কমিশনার)')),
            const SizedBox(height: 10),
            TextField(controller: grade, decoration: const InputDecoration(labelText: 'গ্রেড (যেমন: ৯)')),
            const SizedBox(height: 10),
            TextField(controller: salary, decoration: const InputDecoration(labelText: 'মূল বেতন (গেজেট দেখে বসাও)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('সংরক্ষণ', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    if (saved == true) {
      await JobService.setTarget(post.text.trim(), grade.text.trim(), salary.text.trim());
      _load();
    }
  }

  // ───────────────────────── সার্কুলার ─────────────────────────

  Widget _circularTab() {
    if (_circulars.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.campaign_outlined, size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text('কোনো সার্কুলার নেই', style: TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
            const SizedBox(height: 6),
            Text('নিচের + দিয়ে যোগ করো। আবেদনের শেষ তারিখ দিলে ৭, ৩, ১ দিন আগে আর শেষ দিনে নিজে মনে করিয়ে দেব।',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.45)),
          ]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 90),
      children: _circulars.map(_circularCard).toList(),
    );
  }

  Widget _circularCard(Circular c) {
    final dl = c.daysLeft;
    final ex = c.examDaysLeft;
    final closed = c.status == 'closed';
    return Opacity(
      opacity: closed ? 0.55 : 1,
      child: _card(
        onTap: () => _circularSheet(existing: c),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(c.title,
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 20, color: AppTheme.textMuted),
              onSelected: (v) async {
                if (v == 'edit') _circularSheet(existing: c);
                if (v == 'open') {
                  final ok = await AppLauncher.openUrl(c.url);
                  if (!ok) _snack('লিংক খোলা যায়নি');
                }
                if (v == 'delete') _deleteCircular(c);
                if (v == 'admit_check') _admitCheck(c);
                if (v == 'pdf') openRadarPdf(context, title: c.org.isNotEmpty ? c.org : c.title, pageUrl: c.url);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('✏️ এডিট')),
                if (c.url.isNotEmpty) const PopupMenuItem(value: 'open', child: Text('🔗 লিংক খোলো')),
                if (c.url.isNotEmpty) const PopupMenuItem(value: 'pdf', child: Text('📄 বিজ্ঞপ্তি PDF')),
                if (c.status == 'applied' && AdmitWatcher.on)
                  const PopupMenuItem(value: 'admit_check', child: Text('🔎 প্রবেশপত্র এখনই চেক করো')),
                const PopupMenuItem(value: 'delete', child: Text('🗑️ মুছে ফেলো')),
              ],
            ),
          ]),
          if (c.org.isNotEmpty || c.post.isNotEmpty)
            Text([c.org, c.post].where((e) => e.isNotEmpty).join(' · '),
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _chip('${circularStatusIcons[c.status]} ${circularStatuses[c.status]}', AppTheme.accent,
                onTap: () => _changeStatus(c)),
            if (c.status == 'watching' && dl != null) _chip('আবেদন: ${_daysLabel(dl)}', _urgencyColor(dl)),
            if (ex != null && ex >= 0 && !closed)
              _chip('পরীক্ষা: ${ex == 0 ? 'আজ' : 'আর ${bn(ex)} দিন'}', _urgencyColor(ex)),
            if (c.fee > 0) _chip('ফি ${bn(c.fee)} টাকা', AppTheme.textSecondary),
            if (c.status == 'applied' && AdmitWatcher.on)
              (AdmitWatcher.info(c.id)?['found'] == true)
                  ? _chip('🎫 প্রবেশপত্র এসেছে — দেখো', AppTheme.green, onTap: () => _openAdmit(c))
                  : _chip('🔎 প্রবেশপত্র নজরে আছে', AppTheme.textSecondary, onTap: () => _admitCheck(c)),
          ]),
          if (c.status == 'applied' && AdmitWatcher.on && AdmitWatcher.info(c.id)?['found'] != true) ...[
            const SizedBox(height: 6),
            Text(
              AdmitWatcher.info(c.id)?['err'] is String && (AdmitWatcher.info(c.id)!['err'] as String).isNotEmpty
                  ? '⚠️ ${AdmitWatcher.info(c.id)!['err']}'
                  : 'প্রবেশপত্র এলে জানাব · ${AdmitWatcher.lastCheckText(c.id)}',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
            ),
          ],
          if (c.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(c.note, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.4)),
          ],
        ]),
      ),
    );
  }

  /// প্রবেশপত্রের লিংক (পাওয়া গেলে সেটা, নইলে সার্কুলারের লিংক) খোলে।
  Future<void> _openAdmit(Circular c) async {
    final link = (AdmitWatcher.info(c.id)?['link'] as String?) ?? '';
    final ok = await AppLauncher.openUrl(link.isNotEmpty ? link : c.url);
    if (!ok) _snack('লিংক খোলা যায়নি');
  }

  /// হাতে প্রবেশপত্র চেক। প্রথমবার হলে "নজরদারি শুরু" — এই মুহূর্তে সাইটে যা আছে সেটা পুরনো ধরা হয়।
  Future<void> _admitCheck(Circular c) async {
    _snack('প্রবেশপত্র চেক চলছে…');
    final r = await AdmitWatcher.check(c, notify: false);
    await _load();
    if (!mounted) return;
    switch (r.status) {
      case 'found':
        _snack('🎫 নতুন পাওয়া গেছে: ${r.label}');
        break;
      case 'baseline':
        _snack('নজরদারি শুরু হলো ✓ — সাইটে নতুন প্রবেশপত্র এলেই জানাব');
        break;
      case 'error':
        _snack('⚠️ ${AdmitWatcher.info(c.id)?['err'] ?? 'সাইট খোলা যায়নি'}');
        break;
      default:
        _snack('এখনো নতুন প্রবেশপত্র আসেনি');
    }
  }

  Future<void> _changeStatus(Circular c) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          Text('অবস্থা বদলাও',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final e in circularStatuses.entries)
            ListTile(
              leading: Text(circularStatusIcons[e.key]!, style: const TextStyle(fontSize: 20)),
              title: Text(e.value, style: TextStyle(color: AppTheme.textPrimary)),
              trailing: c.status == e.key ? Icon(Icons.check_rounded, color: AppTheme.accent) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == null || picked == c.status) return;
    final prevStatus = c.status;
    final msg = await JobService.setStatus(c, picked);
    if (picked == 'applied') {
      // নজরদারির ভিত্তি (baseline) এখনই নিয়ে রাখি — এরপর নতুন কিছু এলেই জানাবে
      AdmitWatcher.check(c, notify: false).then((_) {}, onError: (_) {});
    } else if (prevStatus == 'applied') {
      AdmitWatcher.forget(c.id);
    }
    await _load();
    if (!mounted) return;
    if (msg != null) {
      _snack(picked == 'applied' ? '$msg\nডেডলাইনের রিমাইন্ডারও বন্ধ করা হলো ✓' : msg);
    } else if (picked == 'applied') {
      _snack('আবেদনের ডেডলাইনের রিমাইন্ডার বন্ধ করা হলো ✓');
    }
  }

  Future<void> _deleteCircular(Circular c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('মুছে ফেলবে?'),
        content: Text('"${c.title}" ও এর রিমাইন্ডারগুলো মুছে যাবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (ok == true) {
      await JobService.deleteCircular(c);
      _load();
    }
  }

  Future<void> _circularSheet({Circular? existing}) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final org = TextEditingController(text: existing?.org ?? '');
    final post = TextEditingController(text: existing?.post ?? '');
    final fee = TextEditingController(text: (existing?.fee ?? 0) > 0 ? '${existing!.fee}' : '');
    final url = TextEditingController(text: existing?.url ?? '');
    final note = TextEditingController(text: existing?.note ?? '');
    DateTime? deadline = existing?.deadline;
    DateTime? exam = existing?.examDate;
    String? error;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Widget dateBtn(String label, DateTime? value, ValueChanged<DateTime?> onChanged) {
          return Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.event, size: 18),
              label: Text(value == null ? label : formatDateBn(value),
                  overflow: TextOverflow.ellipsis),
              onPressed: () async {
                final d = await _pickDate(value);
                if (d != null) setS(() => onChanged(d));
              },
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(existing == null ? 'নতুন সার্কুলার' : 'সার্কুলার এডিট',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                TextField(controller: title,
                    decoration: const InputDecoration(labelText: 'শিরোনাম * (যেমন: ৪৯তম BCS)')),
                const SizedBox(height: 10),
                TextField(controller: org, decoration: const InputDecoration(labelText: 'প্রতিষ্ঠান (BPSC, ব্যাংক...)')),
                const SizedBox(height: 10),
                TextField(controller: post, decoration: const InputDecoration(labelText: 'পদ')),
                const SizedBox(height: 12),
                Row(children: [
                  dateBtn('আবেদনের শেষ তারিখ', deadline, (d) => deadline = d),
                  const SizedBox(width: 10),
                  dateBtn('পরীক্ষার তারিখ', exam, (d) => exam = d),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: fee,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'আবেদন ফি (টাকা)'),
                ),
                const SizedBox(height: 10),
                TextField(controller: url, decoration: const InputDecoration(labelText: 'আবেদন/বিজ্ঞপ্তির লিংক')),
                const SizedBox(height: 10),
                TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'নোট')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      if (title.text.trim().isEmpty) {
                        setS(() => error = 'শিরোনাম দাও');
                        return;
                      }
                      final c = existing ?? Circular(title: '');
                      c.title = title.text.trim();
                      c.org = org.text.trim();
                      c.post = post.text.trim();
                      c.deadline = deadline;
                      c.examDate = exam;
                      c.fee = int.tryParse(_asciiDigits(fee.text.trim())) ?? 0;
                      c.url = url.text.trim();
                      c.note = note.text.trim();
                      await JobService.saveCircular(c);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('সংরক্ষণ করো'),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
    await _load();
  }

  /// বাংলা অঙ্কে টাইপ করলেও যেন সংখ্যা পার্স হয়।
  String _asciiDigits(String s) {
    const bnd = '০১২৩৪৫৬৭৮৯';
    final b = StringBuffer();
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      final i = bnd.indexOf(c);
      b.write(i >= 0 ? '$i' : c);
    }
    return b.toString();
  }

  // ───────────────────────── ডকুমেন্ট ─────────────────────────

  Widget _docTab() {
    final done = _docs.where((d) => d.done).length;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 90), children: [
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${bn(done)}/${bn(_docs.length)} টা প্রস্তুত',
              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('প্রতিটা সার্কুলারের শর্ত আলাদা — বিজ্ঞপ্তির সাথে মিলিয়ে নিও। মুছতে দীর্ঘক্ষণ চাপো।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
        ]),
      ),
      for (final d in _docs)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: AppTheme.bg2,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () async {
                await JobService.setDocDone(d, !d.done);
                if (mounted) setState(() {});
              },
              onLongPress: () => _deleteDoc(d),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(children: [
                  Checkbox(
                    value: d.done,
                    activeColor: AppTheme.accent,
                    onChanged: (v) async {
                      await JobService.setDocDone(d, v ?? false);
                      if (mounted) setState(() {});
                    },
                  ),
                  Expanded(
                    child: Text(d.title,
                        style: TextStyle(
                          color: d.done ? AppTheme.textMuted : AppTheme.textPrimary,
                          decoration: d.done ? TextDecoration.lineThrough : null,
                          height: 1.35,
                        )),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }

  Future<void> _addDoc() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('নতুন ডকুমেন্ট'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'ডকুমেন্টের নাম'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('যোগ করো', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await JobService.addDoc(ctrl.text.trim());
      _load();
    }
  }

  Future<void> _deleteDoc(JobDoc d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('মুছে ফেলবে?'),
        content: Text('"${d.title}"'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (ok == true) {
      await JobService.deleteDoc(d);
      _load();
    }
  }
}
