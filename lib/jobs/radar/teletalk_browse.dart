import 'package:flutter/material.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../widgets/app_theme.dart';
import '../models/job_models.dart';
import '../services/app_launcher.dart';
import '../services/job_service.dart';
import 'engine/bn_util.dart' show fmtDateBn, todayDhaka, daysBetween;
import 'engine/match_engine.dart' show postRelevance;
import 'engine/teletalk_radar.dart' show teletalkAgeCheck;
import 'engine/teletalk_source.dart';
import '../profile/big_hiring.dart';
import 'apply_flow.dart';
import 'radar_models.dart';
import 'radar_pdf_viewer.dart';
import 'radar_stars.dart';
import 'radar_service.dart';

/// Teletalk AllJobs-এর মতো তালিকা: সব চলমান সরকারি চাকরি, সার্চ ও ফিল্টারসহ।
/// তোমার টার্গেট পদগুলোতে 🎯 চিহ্ন থাকে।
class TeletalkBrowse extends StatefulWidget {
  final VoidCallback onSaved;
  const TeletalkBrowse({super.key, required this.onSaved});
  @override
  State<TeletalkBrowse> createState() => _TeletalkBrowseState();
}

enum _Filter { all, mine, soon3, soon7, newest }

class _TeletalkBrowseState extends State<TeletalkBrowse> {
  List<TeletalkJob> _jobs = [];
  Set<String> _saved = {};
  bool _loading = false;
  String? _error;
  _Filter _filter = _Filter.all;
  bool _bigFirst = true; // 📌 বড় নিয়োগ তালিকার একদম ওপরে
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _jobs = RadarService.teletalkAll();
    _loadSaved();
    if (_jobs.isEmpty) _refresh();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final list = await JobService.circulars();
    if (mounted) setState(() => _saved = list.map((c) => c.url).where((u) => u.isNotEmpty).toSet());
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final j = await fetchTeletalkJobs();
      await RadarService.saveTeletalkAll(j);
      if (mounted) setState(() { _jobs = j; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Teletalk থেকে আনা যায়নি — ইন্টারনেট দেখো'; });
    }
  }

  String _key(TeletalkJob j) => '${j.applyUrl}#${j.jobId}';

  bool _mine(TeletalkJob j) => postRelevance('${j.titleBn} ${j.titleEn}', RadarService.profile()) == 'yes';

  int? _daysLeft(TeletalkJob j) => j.deadline == null ? null : daysBetween(todayDhaka(), j.deadline!);

  /// তালিকার একটা চাকরি → স্টার-তালিকার সার্কুলার (পুরো তথ্যসহ)।
  RadarItem _asItem(TeletalkJob j) {
    final org = j.orgNameBn.isNotEmpty ? j.orgNameBn : j.orgName;
    final title = j.titleBn.isNotEmpty ? j.titleBn : j.titleEn;
    final mine = _mine(j);
    DateTime? day(DateTime? d) => d == null ? null : DateTime(d.year, d.month, d.day);
    return RadarItem(
      url: '${j.detailsUrl}#teletalk',
      title: '$org (Teletalk)',
      verdict: mine ? 'ok' : 'warn',
      org: org,
      deadline: day(j.deadline),
      method: 'অনলাইন — ${j.applyUrl}',
      applyUrl: j.applyUrl,
      posts: [RadarPost(title: title, count: j.vacancy, verdict: mine ? 'ok' : 'warn', checks: const [])],
      published: day(j.published),
      source: 'teletalk',
    );
  }

  Future<void> _watch(TeletalkJob j) async {
    final org = j.orgNameBn.isNotEmpty ? j.orgNameBn : j.orgName;
    final title = j.titleBn.isNotEmpty ? j.titleBn : j.titleEn;
    final note = StringBuffer('Teletalk ${j.jobId}');
    if (j.published != null) note.write('\nআবেদন শুরু: ${fmtDateBn(j.published!)}');
    note.write('\nশর্ত (বয়স/শিক্ষা/টাইপিং) আবেদনের সাইটের বিজ্ঞপ্তিতে দেখো');
    await JobService.saveCircular(Circular(
      title: '$org — $title',
      org: org,
      post: title,
      deadline: j.deadline == null ? null : DateTime(j.deadline!.year, j.deadline!.month, j.deadline!.day),
      fee: 0,
      url: _key(j),
      note: note.toString(),
    ));
    widget.onSaved();
    await _loadSaved();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('সার্কুলার ট্যাবে যোগ হয়েছে — শেষ তারিখের রিমাইন্ডারও সেট হয়েছে')));
    }
  }

  void _showDetail(TeletalkJob j) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _DetailSheet(job: j),
    );
  }

  List<TeletalkJob> _visible() {
    final q = _q.text.trim().toLowerCase();
    var list = _jobs.where((j) {
      final d = _daysLeft(j);
      if (d != null && d < 0) return false;
      if (q.isNotEmpty) {
        final hay = '${j.titleBn} ${j.titleEn} ${j.orgName} ${j.orgNameBn} ${j.shortName}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      switch (_filter) {
        case _Filter.mine:
          return _mine(j);
        case _Filter.soon3:
          return d != null && d <= 3;
        case _Filter.soon7:
          return d != null && d <= 7;
        case _Filter.newest:
        case _Filter.all:
          return true;
      }
    }).toList();
    if (_filter == _Filter.soon3 || _filter == _Filter.soon7) {
      list.sort((a, b) => (_daysLeft(a) ?? 999).compareTo(_daysLeft(b) ?? 999));
    }
    if (_bigFirst && _filter != _Filter.soon3 && _filter != _Filter.soon7) {
      // বড় নিয়োগ (বেশি পদ/পছন্দের শব্দ) সবার আগে, বড় সংখ্যা আগে; বাকিরা API-র নতুন-আগে ক্রমেই
      final thr = BigHiring.threshold;
      final ws = BigHiring.words;
      final big = <TeletalkJob>[];
      final rest = <TeletalkJob>[];
      for (final j in list) {
        (BigHiring.classify(j, thr: thr, ws: ws).big ? big : rest).add(j);
      }
      big.sort((a, b) => (b.vacancy ?? 0).compareTo(a.vacancy ?? 0));
      return [...big, ...rest];
    }
    return list; // API ইতিমধ্যে নতুন-আগে ক্রমে আসে
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible();
    final mineCount = _jobs.where(_mine).length;
    final at = RadarService.teletalkSavedAt();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'পদ / প্রতিষ্ঠান / keyword খোঁজো',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'রিফ্রেশ',
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _refresh,
          ),
        ]),
      ),
      SizedBox(
        height: 46,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _fchip('সব (${bn(_jobs.length)})', _Filter.all),
            _fchip('🎯 আমার পদ (${bn(mineCount)})', _Filter.mine),
            _fchip('৩ দিনে শেষ', _Filter.soon3),
            _fchip('৭ দিনে শেষ', _Filter.soon7),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8, top: 4, bottom: 4),
              child: FilterChip(
                label: const Text('📌 বড় নিয়োগ আগে', style: TextStyle(fontSize: 12.5)),
                selected: _bigFirst,
                onSelected: (v) => setState(() => _bigFirst = v),
              ),
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('⚠️ $_error', style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
        ),
      if (at != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('তালিকা আনা হয়েছে: ${bn(at.day)}/${bn(at.month)} ${bn(at.hour.toString().padLeft(2, '0'))}:${bn(at.minute.toString().padLeft(2, '0'))} · উৎস: alljobs.teletalk.com.bd',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          ),
        ),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Text(_loading ? 'তালিকা আনা হচ্ছে…' : 'কিছু পাওয়া যায়নি',
                    style: TextStyle(color: AppTheme.textMuted)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                itemCount: list.length,
                itemBuilder: (_, i) => _card(list[i]),
              ),
      ),
    ]);
  }

  Widget _fchip(String label, _Filter f) => Padding(
        padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12.5)),
          selected: _filter == f,
          onSelected: (_) => setState(() => _filter = f),
        ),
      );

  Color _urgency(int d) => d <= 3 ? AppTheme.red : (d <= 7 ? AppTheme.yellow : AppTheme.green);

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );

  Widget _card(TeletalkJob j) {
    final d = _daysLeft(j);
    final mine = _mine(j);
    final saved = _saved.contains(_key(j));
    final org = j.orgNameBn.isNotEmpty ? j.orgNameBn : j.orgName;
    final notStarted = j.published != null && daysBetween(todayDhaka(), j.published!) > 0;
    final big = BigHiring.classify(j);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bg2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: big.big ? Colors.amber.withOpacity(0.8) : (mine ? AppTheme.green.withOpacity(0.6) : AppTheme.border),
              width: big.big ? 1.6 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 6, children: [
                if (big.big)
                  _chip(j.vacancy != null && j.vacancy! >= BigHiring.threshold ? '📌 বড় নিয়োগ · ${bn(j.vacancy!)}টি পদ' : '📌 ${big.why}', Colors.amber),
                if (mine) _chip('🎯 আমার পদ', AppTheme.green),
                if (d != null) _chip(d == 0 ? 'আজই শেষ' : 'আর ${bn(d)} দিন', _urgency(d)),
                if (notStarted) _chip('আবেদন শুরু ${fmtDateBn(j.published!)}', AppTheme.accent),
              ]),
            ),
            InkResponse(
              radius: 24,
              onTap: () async {
                final on = await RadarStars.toggle(_asItem(j));
                if (!mounted) return;
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(on ? '⭐ স্টার দেওয়া হয়েছে — "⭐ স্টার" ট্যাবে পাবে' : 'স্টার তোলা হয়েছে')));
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 2),
                child: Icon(RadarStars.isStarred(_asItem(j)) ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 28, color: RadarStars.isStarred(_asItem(j)) ? Colors.amber : AppTheme.textMuted),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(j.titleBn.isNotEmpty ? j.titleBn : j.titleEn,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          if (j.titleBn.isNotEmpty && j.titleEn.isNotEmpty)
            Text(j.titleEn, style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
          const SizedBox(height: 4),
          Text(org, style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          const SizedBox(height: 6),
          Text(
            [
              if (j.vacancy != null) 'পদ: ${bn(j.vacancy!)}টি',
              if (j.deadline != null) 'শেষ: ${fmtDateBn(j.deadline!)}',
              j.jobId,
            ].join('  ·  '),
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            saved
                ? _chip('✔ সেভ করা আছে', AppTheme.textSecondary)
                : FilledButton.tonal(onPressed: () => _watch(j), child: const Text('🔔 সেভ ও রিমাইন্ডার')),
            FilledButton.icon(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: AppTheme.green, foregroundColor: Colors.white),
              onPressed: (d != null && d < 0) ? null : () => ApplyFlow.open(context, _asItem(j)),
              icon: const Icon(Icons.rocket_launch_rounded, size: 17),
              label: const Text('আবেদন করো'),
            ),
            TextButton(onPressed: () => _showDetail(j), child: const Text('📄 শর্ত ও PDF')),
          ]),
        ]),
      ),
    );
  }
}


/// একটি চাকরির শর্ত: বয়স স্বয়ংক্রিয় যাচাই + বিজ্ঞপ্তির PDF/পেজের লিংক।
class _DetailSheet extends StatefulWidget {
  final TeletalkJob job;
  const _DetailSheet({required this.job});
  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  TeletalkDetail? _d;
  bool _loading = true;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await fetchTeletalkDetail(widget.job.primaryId);
      if (mounted) setState(() { _d = d; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'বিস্তারিত আনা যায়নি — ইন্টারনেট দেখো'; });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _openPdf() async {
    // এক ট্যাপে অ্যাপের ভেতরেই PDF — নামানো, ব্রাউজার বা স্ক্রল ছাড়া
    final d = _d;
    await openRadarPdf(
      context,
      title: widget.job.orgNameBn.isNotEmpty ? widget.job.orgNameBn : widget.job.orgName,
      adFile: d?.adFile ?? '',
      pageUrl: widget.job.detailsUrl, // আন্দাজি ঠিকানা ব্যর্থ হলে ভিউয়ার সাইট থেকে আসল ঠিকানা জেনে নেয়
    );
  }

  @override
  Widget build(BuildContext context) {
    final j = widget.job;
    final d = _d;
    final age = teletalkAgeCheck(j, d, RadarService.profile());
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(j.titleBn.isNotEmpty ? j.titleBn : j.titleEn,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(j.orgNameBn.isNotEmpty ? j.orgNameBn : j.orgName,
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Text('⚠️ $_error', style: TextStyle(color: AppTheme.red, fontSize: 12.5))
          else ...[
            if (d != null && d.maxAge != null)
              Text('বয়সসীমা: ${bn(d.minAge ?? 0)}–${bn(d.maxAge!)} বছর',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5)),
            if (age != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${age.icon} ${age.msg}',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.4)),
              ),
            if (d != null && d.adNo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('বিজ্ঞপ্তি নং: ${d.adNo}', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
              ),
            const SizedBox(height: 10),
            Text(
              '⚠️ শিক্ষাগত যোগ্যতা ও টাইপিংয়ের শর্ত শুধু বিজ্ঞপ্তির PDF-এ থাকে — আবেদনের আগে সেটা পড়ে নাও।',
              style: TextStyle(color: AppTheme.yellow, fontSize: 12.5, height: 1.4),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 6, children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
              onPressed: _opening ? null : _openPdf,
              child: Text(_opening ? 'খুঁজছি…' : '📄 বিজ্ঞপ্তি PDF খোলো'),
            ),
            OutlinedButton(
              onPressed: () => AppLauncher.openUrl(j.detailsUrl),
              child: const Text('Teletalk পেজ'),
            ),
          ]),
        ]),
      ),
    );
  }
}
