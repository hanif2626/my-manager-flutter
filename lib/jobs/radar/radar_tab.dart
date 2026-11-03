import 'dart:convert';
import 'package:flutter/material.dart';
import '../../reminder/models/reminder.dart' show bn, Reminder;
import '../../widgets/app_theme.dart';
import '../../cashbook/services/cashbook_notification_service.dart';
import '../../services/notification_service.dart';
import '../services/admit_watcher.dart';
import '../services/app_launcher.dart';
import '../services/job_service.dart';
import 'engine/bn_util.dart' show monthNamesBn, daysBetween, todayDhaka;
import 'engine/teletalk_source.dart' show TeletalkJob;
import '../profile/big_hiring.dart';
import 'phone_alerts_sheet.dart';
import '../profile/job_profile_screen.dart';
import '../profile/job_tags.dart';
import 'apply_flow.dart';
import 'radar_pdf_viewer.dart';
import 'radar_stars.dart';
import 'phone_notif_service.dart';
import 'radar_models.dart';
import 'radar_runner.dart';
import 'radar_service.dart';
import 'teletalk_browse.dart';

/// চাকরি হাবের "রাডার" ট্যাব — Job Radar যে সার্কুলারগুলো তোমার যোগ্যতার সাথে মিলিয়ে
/// বেছেছে সেগুলো এখানে দেখায়। "সেভ ও রিমাইন্ডার" চাপলে সার্কুলার ট্যাবে চলে যায় (রিমাইন্ডারসহ)।
class RadarTab extends StatefulWidget {
  /// সার্কুলার যোগ হলে হাব রিফ্রেশ করার কলব্যাক।
  final VoidCallback onSaved;
  const RadarTab({super.key, required this.onSaved});
  @override
  State<RadarTab> createState() => _RadarTabState();
}

class _RadarTabState extends State<RadarTab> with WidgetsBindingObserver {
  RadarFeed? _feed;
  bool _loading = false;
  bool _showHidden = false;
  int _mode = 0; // 0 = আমার জন্য, 1 = সব সরকারি চাকরি (Teletalk)
  int _filter = 0; // 0 সব · 1 সম্ভাব্য যোগ্য · 2 ৭ দিনে শেষ · 3 নতুন
  int _sort = 0; // 0 শেষ তারিখ আগে · 1 বেশি পদ আগে · 2 ট্যাগ-মিল আগে
  String? _tagSel; // _filter == 4 হলে: নির্দিষ্ট ট্যাগ (null = যেকোনো ট্যাগ)
  String? _error;
  Set<String> _saved = {};
  Set<String> _hidden = {}; // একবারই পড়ি — কার্ড বানানোর সময় প্রতিবার JSON ডিকোড করলে ধীর হতো
  final Set<String> _expanded = {}; // যাচাইয়ের বিস্তারিত খোলা কার্ড

  @override
  void initState() {
    super.initState();
    _feed = RadarService.cached();
    _hidden = RadarService.dismissed();
    WidgetsBinding.instance.addObserver(this);
    _init();
    // আবেদনের সাইট খুলে অ্যাপ বন্ধ হয়ে গিয়ে থাকলেও ফিরে এসে জিজ্ঞেস করবে
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ApplyFlow.askIfPending(context, widget.onSaved);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) ApplyFlow.askIfPending(context, widget.onSaved);
  }

  Future<void> _init() async {
    await PhoneNotifService.sync();
    await RadarService.reload();
    _feed = RadarService.cached();
    await _loadSaved();
    if (mounted) setState(() {});
    // অ্যাপ খুললে: রাতের রিপোর্টের সময় পেরিয়ে থাকলে ও আজকের রিপোর্ট বাকি থাকলে এখনই করে দিই;
    // একেবারে প্রথমবার (ক্যাশ নেই) হলে একবার চালিয়ে দেখাই।
    if (RadarRunner.isDue()) {
      await _refresh(report: true);
    } else if (_feed == null) {
      await _refresh();
    }
  }

  Future<void> _loadSaved() async {
    final list = await JobService.circulars();
    _saved = list.map((c) => c.url).where((u) => u.isNotEmpty).toSet();
  }

  /// এখনই সাইট থেকে পড়ে নতুন করে যাচাই (হাতে রিফ্রেশ — নোটিফিকেশন দেয় না)।
  Future<void> _refresh({bool report = false}) async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final r = await RadarRunner.run(report: report);
      await RadarService.reload();
      await _loadSaved();
      if (mounted) {
        setState(() {
          _feed = RadarService.cached();
          _loading = false;
          _error = r.error;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'রাডার চালানো যায়নি: $e'; });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _watch(RadarItem it) async {
    await JobService.saveCircular(RadarService.toCircular(it));
    _saved.add(it.url);
    widget.onSaved();
    if (mounted) {
      setState(() {});
      _snack('সেভ হয়েছে — সার্কুলার ট্যাবে যোগ হয়েছে, শেষ তারিখের রিমাইন্ডারও সেট হয়েছে');
    }
  }

  Color _urgency(int d) => d <= 3 ? AppTheme.red : (d <= 7 ? AppTheme.yellow : AppTheme.green);

  String _stamp(DateTime d) =>
      '${bn(d.day)}/${bn(d.month)} ${bn(d.hour.toString().padLeft(2, '0'))}:${bn(d.minute.toString().padLeft(2, '0'))}';

  // ───────────────────────── বিল্ড ─────────────────────────

  String _dateShort(DateTime d) {
    final y = d.year != DateTime.now().year ? ' ${bn(d.year)}' : '';
    return '${bn(d.day)} ${monthNamesBn[d.month]}$y';
  }

  List<RadarItem> _visible(List<RadarItem> all) {
    var list = _showHidden ? all : all.where((i) => !_hidden.contains(i.url)).toList();
    final fresh = _feed?.newUrls.toSet() ?? <String>{};
    final tags = JobTags.all();
    switch (_filter) {
      case 1:
        list = list.where((i) => i.verdict == 'ok').toList();
        break;
      case 2:
        list = list.where((i) => i.daysLeft != null && i.daysLeft! <= 7).toList();
        break;
      case 3:
        list = list.where((i) => fresh.contains(i.url)).toList();
        break;
      case 4:
        list = list.where((i) {
          final m = JobTags.match(i, tags: tags);
          return _tagSel == null ? m.isNotEmpty : m.contains(_tagSel);
        }).toList();
        break;
    }
    list = List.of(list);
    if (_sort == 1) {
      list.sort((a, b) => (b.totalVacancy ?? -1).compareTo(a.totalVacancy ?? -1));
    } else if (_sort == 2) {
      list.sort((a, b) {
        final c = JobTags.match(b, tags: tags).length.compareTo(JobTags.match(a, tags: tags).length);
        return c != 0 ? c : (a.daysLeft ?? 999).compareTo(b.daysLeft ?? 999);
      });
    } else {
      list.sort((a, b) => (a.daysLeft ?? 999).compareTo(b.daysLeft ?? 999));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final all = (_feed?.items ?? const <RadarItem>[])
        .where((i) => i.daysLeft == null || i.daysLeft! >= 0)
        .toList();
    final items = _visible(all);

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
        child: Row(children: [
          Expanded(
            child: Text(
              _feed?.generatedAt != null
                  ? 'শেষ খোঁজা ${_stamp(_feed!.generatedAt!)}'
                    '${RadarService.dailyOn ? ' · 🔔 প্রতিদিন ${_timeBn(RadarService.reportHour, RadarService.reportMinute)}' : ' · 🔕 রিপোর্ট বন্ধ'}'
                  : 'রাডার',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          if (_hidden.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _showHidden = !_showHidden),
              child: Text(_showHidden ? 'লুকানো বাদ দাও' : 'লুকানো ${bn(_hidden.length)}টি'),
            ),
          IconButton(
            tooltip: 'আমার জব প্রোফাইল (ট্যাগ)',
            icon: Icon(Icons.badge_outlined, color: AppTheme.textSecondary),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const JobProfileScreen()));
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'রিফ্রেশ',
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'ফোনের নোটিফিকেশন',
            icon: Badge(
              isLabelVisible: PhoneNotifService.alerts().any((a) => a.match),
              smallSize: 8,
              child: Icon(Icons.notifications_active_outlined, color: AppTheme.textSecondary),
            ),
            onPressed: () => showPhoneAlertsSheet(context, onChanged: () {
              if (mounted) setState(() {});
            }),
          ),
          IconButton(
            tooltip: 'সেটিংস',
            icon: Icon(Icons.tune, color: AppTheme.textSecondary),
            onPressed: _settingsSheet,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Wrap(spacing: 8, children: [
          ChoiceChip(
            label: const Text('🎯 আমার জন্য'),
            selected: _mode == 0,
            onSelected: (_) => setState(() => _mode = 0),
          ),
          ChoiceChip(
            label: const Text('📋 সব সরকারি চাকরি'),
            selected: _mode == 1,
            onSelected: (_) => setState(() => _mode = 1),
          ),
          ChoiceChip(
            label: Text('⭐ স্টার${RadarStars.count > 0 ? ' ${bn(RadarStars.count)}' : ''}'),
            selected: _mode == 2,
            onSelected: (_) => setState(() => _mode = 2),
          ),
        ]),
      ),
      if (_error != null && _mode == 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('⚠️ $_error', style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
        ),
      if (_mode == 1)
        Expanded(child: TeletalkBrowse(onSaved: widget.onSaved))
      else if (_mode == 2)
        Expanded(child: _starredBody())
      else
        Expanded(
          child: _feed == null
              ? Center(child: Text(_loading ? 'সার্কুলার খোঁজা হচ্ছে…' : 'রিফ্রেশ চাপো', style: TextStyle(color: AppTheme.textMuted)))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                    itemCount: items.length + 2, // [০] সারাংশ+ফিল্টার, শেষে ফাঁকা/খালি বার্তা
                    itemBuilder: (ctx, i) {
                      if (i == 0) return _header(all);
                      if (i == items.length + 1) {
                        return items.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.only(top: 40),
                                child: Column(children: [
                                  Icon(Icons.radar, size: 44, color: AppTheme.textMuted),
                                  const SizedBox(height: 12),
                                  Text(
                                    all.isEmpty
                                        ? 'এখন তোমার মতো কোনো চলমান সার্কুলার নেই'
                                        : 'এই ফিল্টারে কিছু নেই — "সব" চাপো',
                                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                                  ),
                                ]),
                              )
                            : const SizedBox.shrink();
                      }
                      return _itemCard(items[i - 1]);
                    },
                  ),
                ),
        ),
    ]);
  }

  String _timeBn(int h, int m) {
    final h12 = h % 12 == 0 ? 12 : h % 12;
    final part = h < 12 ? 'সকাল' : (h < 16 ? 'দুপুর' : (h < 18 ? 'বিকাল' : 'রাত'));
    return '$part ${bn(h12)}:${bn(m.toString().padLeft(2, '0'))}';
  }

  /// 📌 বড় নিয়োগ (বেশি পদ/পছন্দের শব্দ) চলছে — "আমার জন্য" তালিকার ওপরেই জানান দেয়; চাপলে সব তালিকায় নিয়ে যায়।
  Widget _bigBanner() {
    final thr = BigHiring.threshold;
    final ws = BigHiring.words;
    final today = todayDhaka();
    final list = RadarService.teletalkAll().where((j) {
      if (j.deadline != null && daysBetween(today, j.deadline!) < 0) return false;
      return BigHiring.classify(j, thr: thr, ws: ws).big;
    }).toList()
      ..sort((a, b) => (b.vacancy ?? 0).compareTo(a.vacancy ?? 0));
    if (list.isEmpty) return const SizedBox.shrink();
    String line(TeletalkJob j) {
      final name = j.titleBn.isNotEmpty ? j.titleBn : j.titleEn;
      final org = j.orgNameBn.isNotEmpty ? j.orgNameBn : j.orgName;
      final d = j.deadline == null ? null : daysBetween(today, j.deadline!);
      return '• $name${j.vacancy != null ? ' — ${bn(j.vacancy!)}টি পদ' : ''}${d == null ? '' : ' · ${d == 0 ? 'আজই শেষ' : 'আর ${bn(d)} দিন'}'}\n   $org';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() => _mode = 1),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.amber.withOpacity(0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.amber.withOpacity(0.55)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('📌 ${bn(list.length)}টি বড় নিয়োগ চলছে',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w800)),
            ),
            Text('সব দেখো ›', style: TextStyle(color: AppTheme.accent, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          for (final j in list.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line(j), style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
            ),
          if (list.length > 3)
            Text('… আরও ${bn(list.length - 3)}টি', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ]),
      ),
    );
  }

  // ── সারাংশ কার্ড + ফিল্টার ──
  Widget _header(List<RadarItem> all) {
    final live = all.where((i) => !_hidden.contains(i.url)).toList();
    var posts = 0;
    var ok = 0;
    var soon = 0;
    for (final i in live) {
      posts += i.totalVacancy ?? 0;
      if (i.verdict == 'ok') ok++;
      if (i.daysLeft != null && i.daysLeft! <= 7) soon++;
    }
    final myTags = JobTags.all();
    final fresh = _feed?.newUrls.toSet() ?? <String>{};
    final freshN = live.where((i) => fresh.contains(i.url)).length;

    Widget stat(String emoji, String value, String label, Color c) => Expanded(
          child: Column(children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(color: c, fontSize: 20, fontWeight: FontWeight.w800, height: 1.1)),
            const SizedBox(height: 2),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11, height: 1.2)),
          ]),
        );

    Widget fchip(int idx, String label) => ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12.5)),
          selected: _filter == idx,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => setState(() => _filter = idx),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _bigBanner(),
      Container(
        margin: const EdgeInsets.only(top: 6, bottom: 10),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppTheme.accent.withOpacity(0.22), AppTheme.bg2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.accent.withOpacity(0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          stat('📡', bn(live.length), 'সার্কুলার', AppTheme.textPrimary),
          stat('👥', posts > 0 ? bn(posts) : '—', 'মোট পদ', AppTheme.accent),
          stat('🟢', bn(ok), 'সম্ভাব্য\nযোগ্য', AppTheme.green),
          stat('⏳', bn(soon), '৭ দিনে\nশেষ', soon > 0 ? AppTheme.red : AppTheme.textSecondary),
        ]),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          fchip(0, 'সব'),
          const SizedBox(width: 6),
          fchip(1, '🟢 যোগ্য'),
          const SizedBox(width: 6),
          fchip(2, '⏳ ৭ দিনে শেষ'),
          const SizedBox(width: 6),
          fchip(3, '🆕 নতুন${freshN > 0 ? ' (${bn(freshN)})' : ''}'),
          if (myTags.isNotEmpty) ...[
            const SizedBox(width: 6),
            ChoiceChip(
              label: Text('🏷️ ট্যাগ', style: const TextStyle(fontSize: 12.5)),
              selected: _filter == 4 && _tagSel == null,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() {
                _filter = (_filter == 4 && _tagSel == null) ? 0 : 4;
                _tagSel = null;
              }),
            ),
            for (final t in myTags) ...[
              const SizedBox(width: 6),
              ChoiceChip(
                label: Text(t.name, style: const TextStyle(fontSize: 12.5)),
                selected: _filter == 4 && _tagSel == t.name,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() {
                  final same = _filter == 4 && _tagSel == t.name;
                  _filter = same ? 0 : 4;
                  _tagSel = same ? null : t.name;
                }),
              ),
            ],
          ],
          const SizedBox(width: 12),
          ActionChip(
            avatar: Icon(_sort == 0 ? Icons.event : (_sort == 1 ? Icons.groups : Icons.sell_outlined), size: 16),
            label: Text(_sort == 0 ? 'শেষ তারিখ আগে' : (_sort == 1 ? 'বেশি পদ আগে' : 'ট্যাগ-মিল আগে'),
                style: const TextStyle(fontSize: 12.5)),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _sort = (_sort + 1) % (myTags.isEmpty ? 2 : 3)),
          ),
        ]),
      ),
      const SizedBox(height: 10),
    ]);
  }

  // ── একটা সার্কুলারের কার্ড ──
  Widget _itemCard(RadarItem it) {
    final ok = it.verdict == 'ok';
    final dl = it.daysLeft;
    final saved = _saved.contains(it.url);
    final hidden = _hidden.contains(it.url);
    final isNew = _feed?.newUrls.contains(it.url) ?? false;
    final urgency = dl == null ? AppTheme.textMuted : _urgency(dl);
    final accent = dl != null && dl <= 3 ? AppTheme.red : (ok ? AppTheme.green : AppTheme.yellow);
    final total = it.totalVacancy;
    final expanded = _expanded.contains(it.url);
    final age = it.ageCheck;

    Widget tile(String emoji, String label, String value, String sub, Color vc) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: AppTheme.bg.withOpacity(0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$emoji $label', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              const SizedBox(height: 3),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: vc, fontSize: 15.5, fontWeight: FontWeight.w800)),
              if (sub.isNotEmpty)
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ]),
          ),
        );

    // সময় কতটা পেরিয়েছে (শুরুর তারিখ জানা থাকলে)
    double? elapsed;
    if (it.published != null && it.deadline != null) {
      final span = it.deadline!.difference(it.published!).inDays;
      if (span > 0) {
        elapsed = (DateTime.now().difference(it.published!).inDays / span).clamp(0.0, 1.0);
      }
    }

    return Opacity(
      opacity: hidden ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.bg2,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 5, color: accent), // জরুরি/যোগ্যতার রঙের পাশের ফিতা
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          _chip(ok ? '🟢 সম্ভাব্য যোগ্য' : '🟡 যাচাই বাকি', ok ? AppTheme.green : AppTheme.yellow),
                          if (isNew) _chip('🆕 নতুন', AppTheme.accent),
                          if (it.source == 'teletalk') _chip('Teletalk', AppTheme.textSecondary),
                          if (it.source == 'merged') _chip('✅ ${bn(1 + it.altUrls.length)}টি সূত্রে মেলানো', AppTheme.green),
                          if (it.notStartedYet) _chip('⏰ শুরু ${_dateShort(it.published!)}', AppTheme.yellow),
                          if (dl != null && dl < 0) _chip('মেয়াদ শেষ', AppTheme.red),
                          for (final t in JobTags.match(it)) _chip('🏷️ $t', AppTheme.accent),
                        ]),
                      ),
                      _starButton(it),
                    ]),
                    const SizedBox(height: 8),
                    Text(it.org.isNotEmpty ? it.org : it.title,
                        style: TextStyle(color: AppTheme.textPrimary, fontSize: 15.5, fontWeight: FontWeight.w800, height: 1.25)),
                    if (it.org.isNotEmpty && it.title != it.org && !it.title.startsWith(it.org))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(it.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.3)),
                      ),
                    const SizedBox(height: 10),
                    // ── মূল তথ্য: পদসংখ্যা · শেষ তারিখ · ফি ──
                    Row(children: [
                      tile('👥', 'পদসংখ্যা', total != null ? '${bn(total)}টি' : 'জানা নেই',
                          it.posts.length > 1 ? '${bn(it.posts.length)}টি পদে' : (it.unknownCountPosts > 0 && total != null ? '+ অজানা' : ''),
                          total != null ? AppTheme.accent : AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      tile('📅', 'শেষ তারিখ', it.deadline == null ? 'অজানা' : _dateShort(it.deadline!),
                          dl == null ? '' : (dl < 0 ? 'শেষ হয়ে গেছে' : (dl == 0 ? 'আজই শেষ!' : 'আর ${bn(dl)} দিন')), urgency),
                      const SizedBox(width: 8),
                      tile('💰', 'ফি', it.fee.isEmpty ? '—' : it.fee, it.fee.isEmpty ? 'বিজ্ঞপ্তিতে দেখো' : '', AppTheme.textPrimary),
                    ]),
                    if (elapsed != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: elapsed,
                          minHeight: 5,
                          backgroundColor: AppTheme.border,
                          valueColor: AlwaysStoppedAnimation(urgency),
                        ),
                      ),
                    ],
                    // ── পদগুলো ──
                    for (final p in it.posts.take(expanded ? 12 : 3)) ...[
                      const SizedBox(height: 10),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Text('📌 ${p.title}',
                              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w700, height: 1.3)),
                        ),
                        if (p.count != null)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${bn(p.count!)} জন',
                                style: TextStyle(color: AppTheme.accent, fontSize: 11.5, fontWeight: FontWeight.w800)),
                          ),
                      ]),
                      if (expanded)
                        ...p.checks.map((c) => Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text('${c.icon} ${c.msg}',
                                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
                            ))
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(p.checks.map((c) => c.icon).join(' '), style: const TextStyle(fontSize: 12.5)),
                        ),
                    ],
                    if (it.posts.length > 3 && !expanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('+ আরও ${bn(it.posts.length - 3)}টি পদ',
                            style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                      ),
                    // ── আরও তথ্য ──
                    if (age != null || it.adNo.isNotEmpty || it.method.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      if (age != null)
                        Text('${age.icon} ${age.msg}',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.35)),
                      if (it.adNo.isNotEmpty)
                        Text('🗂 বিজ্ঞপ্তি নং: ${it.adNo}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                      if (it.method.isNotEmpty)
                        Text('📝 ${it.method}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.35)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (ApplyFlow.bestUrl(it).isNotEmpty && !(dl != null && dl < 0))
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: AppTheme.green,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => ApplyFlow.open(context, it),
                          icon: const Icon(Icons.rocket_launch_rounded, size: 17),
                          label: const Text('আবেদন করো'),
                        ),
                      saved
                          ? _chip('✔ সেভ করা আছে', AppTheme.textSecondary)
                          : FilledButton.tonal(
                              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                              onPressed: () => _watch(it),
                              child: const Text('🔔 সেভ ও রিমাইন্ডার')),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: AppTheme.accent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => openRadarPdf(
                          context,
                          title: it.org.isNotEmpty ? it.org : it.title,
                          adFile: it.adFile,
                          pageUrl: it.url, // Teletalk হলে ভিউয়ার jobId থেকে ফাইলের পাথ নিজেই এনে নেয়
                        ),
                        icon: const Icon(Icons.picture_as_pdf_rounded, size: 17),
                        label: const Text('বিজ্ঞপ্তি PDF'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final ok = await AppLauncher.openUrl(it.url.replaceFirst('#teletalk', ''));
                          if (!ok) _snack('লিংক খোলা যায়নি');
                        },
                        child: const Text('🔗 বিস্তারিত'),
                      ),
                      if (it.altUrls.isNotEmpty)
                        TextButton(
                          onPressed: () async {
                            final ok = await AppLauncher.openUrl(it.altUrls.first);
                            if (!ok) _snack('লিংক খোলা যায়নি');
                          },
                          child: const Text('🔗 অন্য সূত্র'),
                        ),
                      TextButton(
                        onPressed: () => setState(() => expanded ? _expanded.remove(it.url) : _expanded.add(it.url)),
                        child: Text(expanded ? 'কম দেখাও' : '🔍 যাচাই দেখো'),
                      ),
                      TextButton(
                        onPressed: () async {
                          hidden ? await RadarService.restore(it.url) : await RadarService.dismiss(it.url);
                          _hidden = RadarService.dismissed();
                          if (mounted) setState(() {});
                        },
                        child: Text(hidden ? 'ফিরিয়ে আনো' : 'লুকাও'),
                      ),
                    ]),
                    Text('স্বয়ংক্রিয় যাচাই — মূল বিজ্ঞপ্তিই চূড়ান্ত।',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _starButton(RadarItem it) {
    final on = RadarStars.isStarred(it);
    return InkResponse(
      radius: 24,
      onTap: () async {
        final now = await RadarStars.toggle(it);
        if (!mounted) return;
        setState(() {});
        _snack(now ? '⭐ স্টার দেওয়া হয়েছে — "⭐ স্টার" ট্যাবে সহজে পাবে, শেষ তারিখের আগে সতর্কও করব' : 'স্টার তোলা হয়েছে');
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 6, top: 0, bottom: 2),
        child: Icon(on ? Icons.star_rounded : Icons.star_outline_rounded, size: 28, color: on ? Colors.amber : AppTheme.textMuted),
      ),
    );
  }

  /// ⭐ স্টার-দেওয়া সার্কুলার — ফিড থেকে সরে গেলেও এখানে থাকে; চলমান আগে, মেয়াদ-শেষ সবার শেষে।
  Widget _starredBody() {
    final list = RadarStars.items();
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.star_outline_rounded, size: 52, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text('এখনো কোনো সার্কুলারে স্টার দেওয়া হয়নি',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('যেকোনো সার্কুলারের কার্ডের ডানে ওপরের ☆ চাপলে সেটা এখানে জমা থাকবে — পরে সহজে খুঁজে পাবে, শেষ তারিখের আগে সতর্কও আসবে।',
                textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.45)),
          ]),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 90),
      itemCount: list.length,
      itemBuilder: (_, i) => _itemCard(list[i]),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  // ───────────────────────── সেটিংস ও প্রোফাইল ─────────────────────────

  Future<void> _settingsSheet() async {
    await RadarService.reload(); // ব্যাকগ্রাউন্ড চেকের লগ অন্য isolate লেখে — তাজা পড়ি
    final subject = TextEditingController(text: RadarService.subject);
    final typBn = TextEditingController(text: RadarService.typingBn.toString());
    final typEn = TextEditingController(text: RadarService.typingEn.toString());
    var dob = RadarService.dob;
    var edu = RadarService.eduLevel;
    if (!RadarService.eduLevels.containsKey(edu)) edu = 'degree_pass';
    var daily = RadarService.dailyOn;
    var instant = RadarService.instantOn;
    var deadlineAlert = RadarService.deadlineOn;
    var admitWatch = AdmitWatcher.on;
    var checking = false;
    List<String> diagLines = const [];
    var diagLoading = false;
    var time = RadarService.reportTime;
    final inc = List<String>.from(RadarService.includeTerms);
    final exc = List<String>.from(RadarService.excludeTerms);
    final incCtrl = TextEditingController();
    final excCtrl = TextEditingController();

    void addTerm(List<String> list, TextEditingController c, void Function(void Function()) setS) {
      final t = c.text.trim();
      if (t.isEmpty) return;
      if (!list.any((e) => e.toLowerCase() == t.toLowerCase())) setS(() => list.add(t));
      c.clear();
    }

    Widget termChips(List<String> list, void Function(void Function()) setS, {bool lockLast = false}) => Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final t in list)
              InputChip(
                label: Text(t, style: const TextStyle(fontSize: 12.5)),
                visualDensity: VisualDensity.compact,
                onDeleted: (lockLast && list.length <= 1) ? null : () => setS(() => list.remove(t)),
              ),
          ],
        );

    InputDecoration deco(String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        );

    Future<void> persist() => SettingsPersist.save({
          RadarService.kDob: dob,
          RadarService.kEdu: edu,
          RadarService.kSubject: subject.text.trim(),
          RadarService.kTypBn: _num(typBn.text, 20).toString(),
          RadarService.kTypEn: _num(typEn.text, 20).toString(),
          RadarService.kDaily: daily ? '1' : '0',
          RadarService.kInstant: instant ? '1' : '0',
          RadarService.kDeadline: deadlineAlert ? '1' : '0',
          AdmitWatcher.kOn: admitWatch ? '1' : '0',
          RadarService.kReportTime: time,
          RadarService.kKwInclude: jsonEncode(inc),
          RadarService.kKwExclude: jsonEncode(exc),
        });

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('রাডার সেটিংস',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              Text('রাতের রিপোর্ট', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('প্রতিদিন নোটিফিকেশন দাও', style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: Text('উপযুক্ত সার্কুলার, মোট পদসংখ্যা ও শেষ তারিখ — প্রতিদিন নির্দিষ্ট সময়ে একটাই নোটিফিকেশনে',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                value: daily,
                onChanged: (v) => setS(() => daily = v),
              ),
              OutlinedButton(
                onPressed: !daily
                    ? null
                    : () async {
                        final parts = time.split(':');
                        final t = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay(
                              hour: int.tryParse(parts.first) ?? 21, minute: int.tryParse(parts.last) ?? 0),
                        );
                        if (t != null) {
                          setS(() => time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                        }
                      },
                child: Text('রিপোর্টের সময়: ${bn(time.split(':').first)}:${bn(time.split(':').last)}'),
              ),
              const SizedBox(height: 4),
              Text('নোটিফিকেশন ঠিক সময়ে আসার জন্য ফোনের অ্যালার্ম ব্যবহার হয় — অ্যাপ বন্ধ থাকলেও আসবে। '
                  'শেষ খোঁজার তথ্যই দেখানো হয়; অ্যাপ/ব্যাকগ্রাউন্ড টাস্ক চললে তাজা তথ্যে হালনাগাদ হয়।',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 4),
              TextButton.icon(
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: const Text('এখনই একটা পরীক্ষা নোটিফিকেশন দেখো'),
                onPressed: () async {
                  await RadarRunner.sendTestReport();
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('নোটিফিকেশন পাঠানো হয়েছে')));
                },
              ),
              const SizedBox(height: 10),
              Text('নতুন সার্কুলার', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('নতুন সার্কুলার এলেই সাথে সাথে জানাও', style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: Text('দিনে কয়েকবার চুপচাপ খুঁজে নতুন সার্কুলার বা বাড়ানো শেষ তারিখ পেলে আলাদা নোটিফিকেশন (রাত ১১টা–ভোর ৬টা বাদে)',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                value: instant,
                onChanged: (v) => setS(() => instant = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('শেষ তারিখ ঘনিয়ে এলে জানাও', style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: Text('চলমান সার্কুলারের আবেদন শেষ হওয়ার ৩ দিন ও ১ দিন আগে, আর শেষ দিনে সকাল-বিকাল। ফোনের অ্যালার্মে আগেই বসানো থাকে — ইন্টারনেট বা ব্যাকগ্রাউন্ড ছাড়াই আসে। (সেভ-করা সার্কুলারের রিমাইন্ডার চাকরি-হাব আলাদাভাবে দেয়।)',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
                value: deadlineAlert,
                onChanged: (v) => setS(() => deadlineAlert = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('প্রবেশপত্র নজরদারি', style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: Text('যে সার্কুলারের অবস্থা "আবেদন করেছি", তার সাইটে নতুন "প্রবেশপত্র" লিংক বা নোটিশ এলে জানাবে (প্রায় প্রতি ৩ ঘণ্টায় চেক)। ফলাফল এর বাইরে — সেটা আলাদা সাইটে আসে।',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
                value: admitWatch,
                onChanged: (v) => setS(() => admitWatch = v),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bg.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ব্যাকগ্রাউন্ড চেকের অবস্থা', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 4),
                  if (RadarService.bgLog().isEmpty)
                    Text('এখনো ব্যাকগ্রাউন্ডে একবারও চেক হয়নি। নতুন সার্কুলারের নোটিফিকেশন আসতে হলে ফোনকে অ্যাপটা ব্যাকগ্রাউন্ডে চলতে দিতে হবে — নিচের "ব্যাটারি সীমা তুলে দাও" বাটন চাপো।',
                        style: TextStyle(color: AppTheme.yellow, fontSize: 12, height: 1.4))
                  else
                    for (final l in RadarService.bgLog())
                      Text(l, style: TextStyle(color: AppTheme.textSecondary, fontSize: 11.5, height: 1.45)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    FilledButton.tonalIcon(
                      onPressed: checking
                          ? null
                          : () async {
                              setS(() => checking = true);
                              final r = await RadarRunner.run(alertNew: true);
                              await RadarService.reload();
                              if (ctx.mounted) {
                                setS(() => checking = false);
                                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text(r.error != null
                                      ? '⚠️ ${r.error}'
                                      : 'চেক শেষ — ${bn(r.total)}টি সার্কুলার, নতুন ${bn(r.fresh)}টি'),
                                ));
                              }
                            },
                      icon: const Icon(Icons.sync, size: 18),
                      label: Text(checking ? 'চেক চলছে…' : 'এখনই নতুন সার্কুলার চেক করো'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => CashbookNotificationService.requestBatteryExemptionIfNeeded(),
                      icon: const Icon(Icons.battery_saver, size: 18),
                      label: const Text('ব্যাটারি সীমা তুলে দাও'),
                    ),
                  ]),
                  const Divider(height: 22),
                  Text('নোটিফিকেশন কেন আসছে না — পরীক্ষা', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 6),
                  for (final l in diagLines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(l, style: TextStyle(color: AppTheme.textSecondary, fontSize: 11.5, height: 1.4)),
                    ),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    OutlinedButton.icon(
                      onPressed: diagLoading
                          ? null
                          : () async {
                              setS(() => diagLoading = true);
                              await RadarRunner.rearmDaily();
                              final lines = await NotificationService.diagnostics();
                              if (ctx.mounted) setS(() { diagLines = lines; diagLoading = false; });
                            },
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: Text(diagLoading ? 'দেখা হচ্ছে…' : 'অবস্থা দেখো'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await NotificationService.scheduleTestAlarm(seconds: 60);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                            duration: Duration(seconds: 6),
                            content: Text('১ মিনিট পরের পরীক্ষা বসেছে — অ্যাপ বন্ধ করে (রিসেন্ট থেকে সরিয়ে) অপেক্ষা করো। নোটিফিকেশন এলে অ্যালার্ম ঠিক আছে।'),
                          ));
                        }
                      },
                      icon: const Icon(Icons.alarm, size: 18),
                      label: const Text('১ মিনিট পরের পরীক্ষা'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => NotificationService.requestExactAlarmPermission(),
                      icon: const Icon(Icons.verified_user_outlined, size: 18),
                      label: const Text('অ্যালার্ম অনুমতি দাও'),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              Text('তোমার যোগ্যতা', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () async {
                  final init = DateTime.tryParse(dob) ?? DateTime(1999, 1, 1);
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: init,
                    firstDate: DateTime(1960),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setS(() => dob = Reminder.ymd(d));
                },
                child: Text('জন্মতারিখ: ${_dobBn(dob)}'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: edu,
                decoration: deco('সর্বোচ্চ শিক্ষাগত যোগ্যতা'),
                items: RadarService.eduLevels.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setS(() => edu = v ?? edu),
              ),
              const SizedBox(height: 10),
              TextField(controller: subject, decoration: deco('বিষয়/বিভাগ (ঐচ্ছিক)', hint: 'যেমন: বাংলা')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: typBn,
                    keyboardType: TextInputType.number,
                    decoration: deco('বাংলা টাইপিং (WPM)'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: typEn,
                    keyboardType: TextInputType.number,
                    decoration: deco('ইংরেজি টাইপিং (WPM)'),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              Text('কোন পদ খুঁজবে', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('পদের নামে এই শব্দগুলোর কোনোটা থাকলে সার্কুলার ধরা হবে। নিজের পছন্দের পদ যোগ করো, অপ্রয়োজনীয়টা মুছে দাও।',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 8),
              termChips(inc, setS, lockLast: true),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: incCtrl,
                    decoration: deco('নতুন পদ যোগ করো', hint: 'যেমন: অফিস সহায়ক, ক্যাশিয়ার'),
                    onSubmitted: (_) => addTerm(inc, incCtrl, setS),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.add_circle, color: AppTheme.accent),
                  onPressed: () => addTerm(inc, incCtrl, setS),
                ),
              ]),
              const SizedBox(height: 14),
              Text('যে শব্দ থাকলে বাদ দেবে', style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              termChips(exc, setS),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: excCtrl,
                    decoration: deco('বাদ দেওয়ার শব্দ যোগ করো'),
                    onSubmitted: (_) => addTerm(exc, excCtrl, setS),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.add_circle, color: AppTheme.accent),
                  onPressed: () => addTerm(exc, excCtrl, setS),
                ),
              ]),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setS(() {
                    inc
                      ..clear()
                      ..addAll(RadarService.defaultInclude);
                    exc
                      ..clear()
                      ..addAll(RadarService.defaultExclude);
                  }),
                  child: const Text('পদের তালিকা ডিফল্টে ফেরাও'),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
                  onPressed: () async {
                    await persist();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('সংরক্ষণ'),
                ),
              ),
            ]),
          ),
        );
      }),
    );

    for (final c in [subject, typBn, typEn, incCtrl, excCtrl]) {
      c.dispose();
    }
    if (mounted) setState(() {});
    await RadarRunner.markStale();
    try {
      await RadarRunner.rearmDaily(); // সময় বা চালু/বন্ধ বদলালে নির্ধারিত নোটিফিকেশন নতুন করে বসে
    } catch (_) {}
    await _refresh(); // প্রোফাইল বদলালে নতুন করে যাচাই
  }

  static int _num(String s, int fallback) {
    const d = '০১২৩৪৫৬৭৮৯';
    final en = s.replaceAllMapped(RegExp('[০-৯]'), (m) => d.indexOf(m[0]!).toString());
    final n = int.tryParse(en.trim());
    return (n == null || n <= 0) ? fallback : n;
  }

  static String _dobBn(String ymd) {
    final d = DateTime.tryParse(ymd);
    return d == null ? ymd : '${bn(d.day)}/${bn(d.month)}/${bn(d.year)}';
  }
}
