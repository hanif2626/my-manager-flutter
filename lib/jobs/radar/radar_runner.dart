import 'dart:convert';
import '../../reminder/models/reminder.dart' show Reminder;
import '../../services/notification_service.dart';
import '../../services/settings_service.dart';
import 'engine/bdgovtjob_source.dart';
import 'engine/bn_util.dart';
import 'engine/match_engine.dart';
import 'engine/merge_items.dart';
import '../profile/job_tags.dart';
import 'radar_stars.dart';
import 'engine/teletalk_radar.dart';
import 'engine/teletalk_source.dart';
import '../services/admit_watcher.dart';
import '../services/job_service.dart';
import 'radar_models.dart';
import 'radar_service.dart';

class RadarRunSummary {
  final int total; // তালিকায় মোট চলমান উপযুক্ত
  final int ok;
  final int warn;
  final int fresh; // নতুন
  final String? error;
  const RadarRunSummary({this.total = 0, this.ok = 0, this.warn = 0, this.fresh = 0, this.error});
}

/// রাডার চালায়: সাইট থেকে পড়া → যাচাই → ক্যাশ → (রাতে) একটাই নোটিফিকেশন।
/// অ্যাপ খোলা অবস্থায় ও ব্যাকগ্রাউন্ড টাস্ক — দুই জায়গা থেকেই চলে।
class RadarRunner {
  static const _kState = 'radar_runner_state';
  static const _kRunning = 'radar_running_at';
  static const _maxFetch = 25;
  static const _engineVersion = 3; // যাচাই-নিয়ম বদলালে বাড়াই — পুরনো ফলাফল আবার যাচাই হবে

  static String _today() => Reminder.ymd(DateTime.now());

  static Map<String, dynamic> _loadState() {
    final raw = SettingsService.getString(_kState);
    if (raw.isEmpty) return {'items': <String, dynamic>{}, 'lastReport': '', 'reported': <dynamic>[]};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {'items': <String, dynamic>{}, 'lastReport': '', 'reported': <dynamic>[]};
    }
  }

  /// আজকের রিপোর্ট বাকি আছে এবং রিপোর্টের সময় পেরিয়েছে কি না।
  static bool isDue([DateTime? now]) {
    if (!RadarService.dailyOn) return false;
    final n = now ?? DateTime.now();
    final at = DateTime(n.year, n.month, n.day, RadarService.reportHour, RadarService.reportMinute);
    if (n.isBefore(at)) return false;
    return _loadState()['lastReport'] != _today();
  }

  /// প্রোফাইল বদলালে: সব সংরক্ষিত ফলাফল "পুরনো" চিহ্নিত — পরের রানে নতুন প্রোফাইলে আবার যাচাই হবে।
  static Future<void> markStale() async {
    final s = _loadState();
    final items = Map<String, dynamic>.from((s['items'] as Map?) ?? {});
    for (final k in items.keys.toList()) {
      final v = Map<String, dynamic>.from(items[k] as Map);
      v['modified'] = null;
      v['checkedAt'] = 0;
      items[k] = v;
    }
    s['items'] = items;
    await SettingsService.setString(_kState, jsonEncode(s));
  }

  /// WorkManager-এর ব্যাকগ্রাউন্ড টাস্ক থেকে: runIfDue চালায় আর ফলাফল/ত্রুটি লগে রাখে — যাতে সেটিংসে
  /// দেখা যায় ফোন আসলেই ব্যাকগ্রাউন্ডে চলতে দিচ্ছে কি না (চলে থাকলে লগে তারিখ-সময় থাকবে)।
  static Future<void> runFromBackground() async {
    try {
      await rearmDaily();
    } catch (_) {}
    // আবেদন-করা সার্কুলারের প্রবেশপত্র নজরদারি (নিজের ৩ ঘণ্টার শর্ত আছে)
    try {
      final a = await AdmitWatcher.checkAllIfDue();
      if (a.checked > 0) {
        await RadarService.addBgLog('প্রবেশপত্র চেক — ${a.checked}টি সার্কুলার${a.found > 0 ? ', নতুন ${a.found}টিতে পাওয়া গেছে' : ''}');
      }
    } catch (_) {}
    try {
      final r = await runIfDue();
      if (r == null) {
        await RadarService.addBgLog('চেক হয়েছে — এখন নতুন করে খোঁজার দরকার ছিল না');
      } else if (r.error != null) {
        await RadarService.addBgLog('ত্রুটি: ${r.error}');
      } else {
        await RadarService.addBgLog('খোঁজা হয়েছে — ${r.total}টি সার্কুলার, নতুন ${r.fresh}টি');
      }
    } catch (e) {
      try {
        await RadarService.addBgLog('ত্রুটি: $e');
      } catch (_) {}
    }
  }

  /// সময় হলে চালিয়ে নোটিফিকেশন দেয়। ব্যাকগ্রাউন্ড টাস্ক ও অ্যাপ চালু — দুই জায়গা থেকেই ডাকা হয়।
  static Future<RadarRunSummary?> runIfDue() async {
    await RadarService.reload();
    // সবার আগে সর্বশেষ জানা তথ্য দিয়ে অ্যালার্মগুলো বসিয়ে ফেলি (নেটওয়ার্ক ছাড়াই, তাৎক্ষণিক)। আগে এটা খোঁজা শেষ
    // হওয়ার পরে হতো — খোঁজার মাঝে নেট চলে গেলে বা অ্যাপ বন্ধ হয়ে গেলে অ্যালার্ম কখনো বসতই না।
    try {
      await rearmDaily();
    } catch (_) {}
    try {
      await AdmitWatcher.checkAllIfDue(); // অ্যাপ খোলা/resume-এও প্রবেশপত্র চেক (৩ ঘণ্টায় একবার)
    } catch (_) {}
    if (isDue()) return run(report: true);
    // দিনের বেলা প্রতি ~৩ ঘণ্টায় চুপচাপ একবার খুঁজি: (১) নতুন যোগ্য সার্কুলার/বাড়ানো শেষ তারিখ এলে সাথে সাথে
    // জানাতে, (২) রাতের নোটিফিকেশনে যেন তাজা তথ্য থাকে। রাত ১১টা থেকে ভোর ৬টা পর্যন্ত খুঁজি না।
    final h = DateTime.now().hour;
    if ((RadarService.dailyOn || RadarService.instantOn) && h >= 6 && h < 23) {
      final lastAt = (_loadState()['lastRunAt'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - lastAt >= 3 * 3600 * 1000) {
        return run(alertNew: true);
      }
    }
    await rearmDaily(); // নির্ধারিত সময়ের অ্যালার্ম ঠিকঠাক বসে আছে কি না — নিশ্চিত করি
    return null;
  }

  /// এখনই চালায়। [report] সত্য হলে রাতের নোটিফিকেশন দেয় ও "আজকের রিপোর্ট হয়ে গেছে" চিহ্নিত করে।
  static Future<RadarRunSummary> run({bool report = false, bool alertNew = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final running = SettingsService.getInt(_kRunning);
    if (running != 0 && now - running < 10 * 60 * 1000) {
      return const RadarRunSummary(error: 'আরেকটা রান চলছে — একটু পরে দেখো');
    }
    await SettingsService.setInt(_kRunning, now);
    try {
      return await _run(report, alertNew);
    } catch (e) {
      try {
        await rearmDaily();
      } catch (_) {}
      rethrow;
    } finally {
      await SettingsService.setInt(_kRunning, 0);
    }
  }

  static Future<RadarRunSummary> _run(bool report, bool alertNew) async {
    final profile = RadarService.profile();
    final state = _loadState();
    final items = Map<String, dynamic>.from((state['items'] as Map?) ?? {});
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (state['v'] != _engineVersion) {
      // নিয়ম বদলেছে: সব এন্ট্রি "পুরনো" চিহ্নিত — এই রানেই নতুন নিয়মে আবার যাচাই হবে
      for (final k in items.keys.toList()) {
        final v = Map<String, dynamic>.from(items[k] as Map);
        v['modified'] = null;
        v['checkedAt'] = 0;
        items[k] = v;
      }
      state['v'] = _engineVersion;
    }

    List<ListedPost> list;
    try {
      list = await listLatest(limit: 40);
    } catch (e) {
      list = [];
    }
    var fetched = 0;
    for (final it in list) {
      final prev = items[it.url] as Map?;
      if (prev != null) {
        if (it.modified != null && prev['modified'] == it.modified) continue;
        if (it.modified == null && nowMs - ((prev['checkedAt'] as num?)?.toInt() ?? 0) < 6 * 3600 * 1000) continue;
      }
      if (fetched >= _maxFetch) break;
      fetched++;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      FetchedDetail d;
      try {
        d = await fetchDetail(it.url);
      } catch (_) {
        continue;
      }
      final title = it.title.isNotEmpty ? it.title : d.title;
      final r = evaluate(d.text, profile, title: title);
      final good = (r.verdict == 'ok' || r.verdict == 'warn') && !r.expired;
      items[it.url] = {
        'modified': it.modified,
        'checkedAt': nowMs,
        'item': good
            ? RadarItem(
                url: it.url,
                title: title,
                verdict: r.verdict,
                org: r.org,
                deadline: r.nearest == null ? null : DateTime(r.nearest!.year, r.nearest!.month, r.nearest!.day),
                method: r.method,
                fee: r.fee,
                posts: r.posts.where((p) => p.verdict != 'fail').toList(),
              ).toMap()
            : null,
      };
    }

    // ── Teletalk (সরাসরি সরকারি উৎস) ──
    var teletalkOk = true;
    try {
      final tj = await fetchTeletalkJobs();
      await RadarService.saveTeletalkAll(tj);
      // আগের Teletalk এন্ট্রি মুছে নতুন তালিকা বসাই (পদ সরে গেলে/শেষ হলে ঠিক থাকে)
      items.removeWhere((k, _) => k.toString().startsWith('teletalk:'));
      // শুধু আমাদের টার্গেট পদগুলোর বিস্তারিত আনি (সাধারণত অল্প ক'টা) — বয়সসীমা যাচাইয়ের জন্য
      final details = <int, TeletalkDetail>{};
      for (final t in pickTeletalkTargets(tj, profile)) {
        try {
          details[t.primaryId] = await fetchTeletalkDetail(t.primaryId);
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      for (final ri in teletalkItems(tj, profile, details: details)) {
        items['teletalk:${ri.url}'] = {'modified': null, 'checkedAt': nowMs, 'item': ri.toMap()};
      }
    } catch (_) {
      teletalkOk = false;
    }
    if (list.isEmpty && !teletalkOk) {
      // দুটো উৎসই ব্যর্থ — আগের ক্যাশ যেমন আছে থাকুক; রিপোর্ট চিহ্নিত হবে না, পরের ঘণ্টায় আবার চেষ্টা।
      return const RadarRunSummary(error: 'সাইট থেকে তালিকা পাওয়া যায়নি — ইন্টারনেট/সাইট দেখো');
    }

    // ১২০ দিনের পুরনো এন্ট্রি ছাঁটাই
    items.removeWhere((_, v) => nowMs - (((v as Map)['checkedAt'] as num?)?.toInt() ?? 0) > 120 * 86400000);

    // ফিড: চলমান, উপযুক্ত — শেষ তারিখ অনুযায়ী
    final feedItems = <RadarItem>[];
    for (final v in items.values) {
      final m = (v as Map)['item'];
      if (m == null) continue;
      final ri = RadarItem.fromMap(Map<String, dynamic>.from(m as Map));
      if (ri.daysLeft != null && ri.daysLeft! < 0) continue;
      feedItems.add(ri);
    }
    // একই সার্কুলার দুই উৎসে থাকলে এক কার্ড
    final merged = mergeDuplicates(feedItems);
    feedItems
      ..clear()
      ..addAll(merged);
    feedItems.sort((a, b) => (a.daysLeft ?? 999).compareTo(b.daysLeft ?? 999));

    final reported = ((state['reported'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final fresh = feedItems.where((i) => !reported.contains(i.url)).map((i) => i.url).toList();

    final feed = RadarFeed(generatedAt: DateTime.now(), items: feedItems, newUrls: fresh);
    await RadarService.saveFeed(feed);

    state['items'] = items;
    state['lastRun'] = _today();
    state['lastRunAt'] = nowMs;
    try {
      await RadarStars.refreshFrom(feedItems); // স্টার-দেওয়া সার্কুলারের তথ্য তাজা রাখি
    } catch (_) {}
    await _instantAlerts(state, feedItems, notify: alertNew && !report && RadarService.instantOn);
    if (report) {
      await _notify(feed);
      state['lastReport'] = _today();
      state['reported'] = feedItems.map((i) => i.url).toList(); // এখনকার সবই \"জানানো\" হলো
    }
    await SettingsService.setString(_kState, jsonEncode(state));
    // এই ফলাফল নিয়ে আগামী কয়েক রাতের নোটিফিকেশন নির্ধারিত সময়ে বসিয়ে রাখি।
    try {
      await rearmDaily();
    } catch (_) {}

    final ok = feedItems.where((i) => i.verdict == 'ok').length;
    return RadarRunSummary(total: feedItems.length, ok: ok, warn: feedItems.length - ok, fresh: fresh.length);
  }

  // ── রাতের নোটিফিকেশন ──

  /// [ref] দিনের হিসাবে বার্তা: শিরোনাম, এক লাইনের সারাংশ, আর পুরো তালিকা।
  /// মোট পদসংখ্যা, নতুন, দ্রুত-শেষ হওয়া — সব এখানেই।
  static ({String head, String short, String big}) _compose(
      List<RadarItem> all, Set<String> fresh, DateTime ref) {
    // ref দিনে যেগুলো চলমান (মেয়াদ শেষ হয়নি), শেষ তারিখ অনুযায়ী সাজানো
    final its = all.where((i) => (i.daysLeftAt(ref) ?? 999) >= 0).toList()
      ..sort((a, b) => (a.daysLeftAt(ref) ?? 999).compareTo(b.daysLeftAt(ref) ?? 999));
    if (its.isEmpty) {
      return (
        head: '📡 আজকের রাডার',
        short: 'আজ তোমার যোগ্যতার সাথে মেলে এমন চলমান সার্কুলার নেই।',
        big: 'আজ তোমার যোগ্যতার সাথে মেলে এমন চলমান সার্কুলার নেই। কাল আবার দেখব।',
      );
    }
    final ok = its.where((i) => i.verdict == 'ok').length;
    final warn = its.length - ok;
    var totalPosts = 0;
    for (final i in its) {
      totalPosts += i.totalVacancy ?? 0;
    }
    final urgent = its.where((i) => (i.daysLeftAt(ref) ?? 999) <= 3).length;
    final freshN = its.where((i) => fresh.contains(i.url)).length;

    final head = '📡 ${toBnStr(its.length)}টি সার্কুলার'
        '${totalPosts > 0 ? ' · মোট ${toBnStr(totalPosts)}টি পদ' : ''}'
        '${freshN > 0 ? ' · 🆕 ${toBnStr(freshN)}টি নতুন' : ''}';
    final short = [
      if (urgent > 0) '🔥 ${toBnStr(urgent)}টির শেষ ৩ দিনের মধ্যে',
      '🟢 ${toBnStr(ok)}টি সম্ভাব্য যোগ্য',
      if (warn > 0) '🟡 ${toBnStr(warn)}টি যাচাই বাকি',
    ].join(' · ');

    final lines = <String>[];
    for (final i in its.take(8)) {
      final dl = i.daysLeftAt(ref);
      final when = dl == null ? '' : (dl == 0 ? 'আজই শেষ!' : 'আর ${toBnStr(dl)} দিন');
      final vac = i.totalVacancy == null ? '' : '${toBnStr(i.totalVacancy)} পদ';
      final tg = JobTags.match(i);
      final meta = [vac, when, if (tg.isNotEmpty) '🏷️ ${tg.join(', ')}'].where((e) => e.isNotEmpty).join(' · ');
      final mark = fresh.contains(i.url) ? '🆕' : (dl != null && dl <= 3 ? '🔥' : (i.verdict == 'ok' ? '🟢' : '🟡'));
      final name = i.org.isNotEmpty ? i.org : i.title;
      lines.add('$mark $name${meta.isEmpty ? '' : '\n    $meta'}');
    }
    if (its.length > 8) lines.add('… আরও ${toBnStr(its.length - 8)}টি — অ্যাপে দেখো');
    return (head: head, short: short, big: '$short\n\n${lines.join('\n')}');
  }

  /// সেটিংসের "পরীক্ষা" বাটন: সর্বশেষ ফলাফল থেকে এখনই একটা নোটিফিকেশন দেখায় (আজকের রিপোর্ট "হয়ে গেছে" ধরে না)।
  static Future<void> sendTestReport() async {
    await RadarService.reload();
    final feed = RadarService.cached();
    if (feed == null) {
      await NotificationService.showRadarReport(
          '📡 রাডার পরীক্ষা', 'এখনো কোনো খোঁজার ফলাফল নেই', 'আগে রিফ্রেশ চেপে একবার খুঁজে নাও।');
      return;
    }
    final m = _compose(feed.items, feed.newUrls.toSet(), DateTime.now());
    await NotificationService.showRadarReport(m.head, m.short, m.big);
  }

  static Future<void> _notify(RadarFeed feed) async {
    final m = _compose(feed.items, feed.newUrls.toSet(), DateTime.now());
    await NotificationService.showRadarReport(m.head, m.short, m.big);
  }

  // ── নতুন সার্কুলার / বাড়ানো শেষ তারিখ: সাথে সাথে জানানো ──

  static Set<String> _keysOf(RadarItem i) => {i.url, ...i.altUrls};

  /// state-এ "জানা আছে" তালিকা হালনাগাদ করে; [notify] সত্য হলে নতুন/সময়-বাড়ানোগুলো এখনই জানায়।
  /// একেবারে প্রথমবার (তালিকা ছিল না) শুধু তালিকা বানায়, জানায় না — যাতে পুরনো সব একসাথে হুড়মুড় করে না আসে।
  static Future<void> _instantAlerts(Map<String, dynamic> state, List<RadarItem> feed, {required bool notify}) async {
    final seeded = state.containsKey('alerted');
    final known = <String>{
      ...((state['alerted'] as List?) ?? const []).map((e) => e.toString()),
      ...((state['reported'] as List?) ?? const []).map((e) => e.toString()),
    };
    final dlMap = Map<String, dynamic>.from((state['dl'] as Map?) ?? {});
    final hidden = RadarService.dismissed();

    final fresh = <RadarItem>[];
    final extended = <RadarItem>[];
    for (final i in feed) {
      if (hidden.contains(i.url)) continue;
      final isKnown = _keysOf(i).any(known.contains);
      if (!isKnown) {
        fresh.add(i);
      } else if (i.deadline != null) {
        final old = _keysOf(i).map((k) => dlMap[k]).whereType<String>().fold<String?>(null, (p, e) => p ?? e);
        if (old != null && Reminder.ymd(i.deadline!).compareTo(old) > 0) extended.add(i);
      }
    }

    if (seeded && notify && (fresh.isNotEmpty || extended.isNotEmpty)) {
      try {
        final m = _composeInstant(fresh, extended);
        await NotificationService.showRadarNew(m.title, m.short, m.big);
      } catch (_) {}
    }

    // জানা-তালিকা ও তারিখ হালনাগাদ (ছোট রাখি)
    for (final i in feed) {
      known.addAll(_keysOf(i));
      if (i.deadline != null) {
        final ymd = Reminder.ymd(i.deadline!);
        for (final k in _keysOf(i)) {
          dlMap[k] = ymd;
        }
      }
    }
    final knownList = known.toList();
    state['alerted'] = knownList.length > 400 ? knownList.sublist(knownList.length - 400) : knownList;
    final liveKeys = feed.expand(_keysOf).toSet();
    dlMap.removeWhere((k, _) => !liveKeys.contains(k));
    state['dl'] = dlMap;
  }

  static ({String title, String short, String big}) _composeInstant(List<RadarItem> fresh, List<RadarItem> extended) {
    String line(RadarItem i) {
      final dl = i.daysLeft;
      final vac = i.totalVacancy == null ? 'পদসংখ্যা জানা নেই' : '${toBnStr(i.totalVacancy)}টি পদ';
      final when = i.deadline == null
          ? ''
          : ' · শেষ ${fmtDateBn(i.deadline!)}${dl == null ? '' : (dl == 0 ? ' (আজই!)' : ' (আর ${toBnStr(dl)} দিন)')}';
      final posts = i.posts.take(2).map((p) => p.title).join(', ');
      final name = i.org.isNotEmpty ? i.org : i.title;
      final mark = i.verdict == 'ok' ? '🟢' : '🟡';
      return '$mark $name\n    $vac$when${posts.isEmpty ? '' : '\n    পদ: $posts'}';
    }

    final lines = <String>[
      ...fresh.take(5).map(line),
      if (fresh.length > 5) '… আরও ${toBnStr(fresh.length - 5)}টি — অ্যাপে দেখো',
      ...extended.take(4).map((i) => '⏳ সময় বেড়েছে: ${i.org.isNotEmpty ? i.org : i.title}\n    নতুন শেষ তারিখ ${fmtDateBn(i.deadline!)}'),
    ];
    String title;
    String short;
    if (fresh.isNotEmpty) {
      final f = fresh.first;
      final name = f.org.isNotEmpty ? f.org : f.title;
      var total = 0;
      for (final i in fresh) {
        total += i.totalVacancy ?? 0;
      }
      title = fresh.length == 1 ? '🆕 নতুন সার্কুলার: $name' : '🆕 ${toBnStr(fresh.length)}টি নতুন সার্কুলার';
      short = [
        if (total > 0) 'মোট ${toBnStr(total)}টি পদ',
        if (extended.isNotEmpty) '⏳ ${toBnStr(extended.length)}টির সময় বেড়েছে',
        if (fresh.length == 1 && f.deadline != null) 'শেষ ${fmtDateBn(f.deadline!)}',
      ].join(' · ');
      if (short.isEmpty) short = 'বিস্তারিত অ্যাপে দেখো';
    } else {
      final e = extended.first;
      title = '⏳ আবেদনের সময় বেড়েছে: ${e.org.isNotEmpty ? e.org : e.title}';
      short = 'নতুন শেষ তারিখ ${fmtDateBn(e.deadline!)}';
    }
    return (title: title, short: short, big: lines.join('\n'));
  }

  /// আগামী ৩ রাতের রিপোর্ট নির্ধারিত সময়ে (exact alarm) বসায় — অ্যাপ বন্ধ থাকলেও, ব্যাকগ্রাউন্ড টাস্ক
  /// দেরি করলেও প্রতিদিন নির্দিষ্ট সময়ে নোটিফিকেশন আসবে। বিষয়বস্তু সর্বশেষ খোঁজা ফলাফল থেকে;
  /// প্রতিটা দিনের \"আর কত দিন\" ওই দিনের হিসাবে। নতুন করে খোঁজা হলে/অ্যাপ খুললে আবার বসে।
  static Future<void> rearmDaily() async {
    try {
      await _rearmReportAlarms();
    } catch (_) {}
    try {
      await rearmDeadlineAlarms();
    } catch (_) {}
  }

  /// চলমান সার্কুলারের আবেদন শেষ হওয়ার আগে: ৩ দিন আগে সকাল ৯টা, ১ দিন আগে সকাল ৯টা, শেষ দিনে সকাল ৮টা
  /// ও বিকাল ৪টা — ফোনের অ্যালার্মে আগেই বসানো, তাই ব্যাকগ্রাউন্ড টাস্ক না চললেও আসে।
  /// "সেভ করা" সার্কুলারের জন্য চাকরি-হাব নিজেই রিমাইন্ডার বানায়, তাই সেগুলো এখানে বাদ (দুবার জানানো ঠেকাতে)।
  static Future<void> rearmDeadlineAlarms() async {
    if (!RadarService.deadlineOn) {
      await NotificationService.cancelRadarDeadlineAlarms();
      return;
    }
    final feed = RadarService.cached();
    final now = DateTime.now();
    final hidden = RadarService.dismissed();
    // ফিডের সার্কুলার + ⭐ স্টার-দেওয়াগুলো (ফিড থেকে সরে গেলেও শেষ তারিখের আগে সতর্ক করতে)
    final pool = <RadarItem>[...?feed?.items];
    for (final st in RadarStars.items()) {
      final k = RadarStars.keysOf(st);
      if (!pool.any((p) => RadarStars.keysOf(p).any(k.contains))) pool.add(st);
    }
    if (pool.isEmpty) return;
    var saved = <String>{};
    try {
      saved = (await JobService.circulars()).map((c) => c.url).where((u) => u.isNotEmpty).toSet();
    } catch (_) {}

    final items = pool
        .where((i) =>
            i.deadline != null &&
            !hidden.contains(i.url) &&
            !_keysOf(i).any(saved.contains) &&
            (i.daysLeftAt(now) ?? -1) >= 0)
        .toList()
      ..sort((a, b) => a.deadline!.compareTo(b.deadline!));

    final msgs = <({DateTime when, String title, String body, String big})>[];
    for (final i in items.take(30)) {
      final dl = DateTime(i.deadline!.year, i.deadline!.month, i.deadline!.day);
      final name = i.org.isNotEmpty ? i.org : i.title;
      final vac = i.totalVacancy == null ? '' : '${toBnStr(i.totalVacancy)}টি পদ';
      for (final slot in const [(3, 9, 0), (1, 9, 0), (0, 8, 0), (0, 16, 0)]) {
        final off = slot.$1;
        final when = DateTime(dl.year, dl.month, dl.day - off, slot.$2, slot.$3);
        if (!when.isAfter(now)) continue;
        final title = off == 0 ? '🚨 আজই আবেদনের শেষ দিন: $name' : '⏳ আবেদনের আর ${toBnStr(off)} দিন বাকি: $name';
        final body = [if (vac.isNotEmpty) vac, 'শেষ ${fmtDateBn(dl)}', if (i.fee.isNotEmpty) 'ফি ${i.fee}'].join(' · ');
        final lines = <String>[
          body,
          ...i.posts.take(4).map((p) => '📌 ${p.title}${p.count == null ? '' : ' — ${toBnStr(p.count)} জন'}'),
          if (i.posts.length > 4) '… আরও ${toBnStr(i.posts.length - 4)}টি পদ',
          if (i.method.isNotEmpty) '📝 ${i.method}',
          'রাডারে "📄 বিজ্ঞপ্তি PDF" চেপে এক ট্যাপে বিজ্ঞপ্তি দেখো।',
        ];
        msgs.add((when: when, title: title, body: body, big: lines.join('\n')));
      }
    }
    await NotificationService.scheduleRadarDeadlineAlarms(msgs);
  }

  static Future<void> _rearmReportAlarms() async {
    if (!RadarService.dailyOn) {
      await NotificationService.cancelRadarAlarms();
      return;
    }
    final now = DateTime.now();
    final feed = RadarService.cached();
    final reported = ((_loadState()['reported'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final msgs = <({DateTime when, String title, String body, String big})>[];
    for (var d = 0; d < 3; d++) {
      final day = DateTime(now.year, now.month, now.day + d);
      final when = DateTime(day.year, day.month, day.day, RadarService.reportHour, RadarService.reportMinute);
      if (!when.isAfter(now)) continue;
      if (feed == null) {
        msgs.add((
          when: when,
          title: '📡 আজকের রাডার',
          body: 'নতুন সরকারি চাকরির সার্কুলার দেখো',
          big: 'আজকের রাডার প্রস্তুত — অ্যাপ খুলে যোগ্য সার্কুলার ও পদসংখ্যা দেখো।',
        ));
        continue;
      }
      // আজকের জন্য: এখনো \"জানানো\" হয়নি এমনগুলো = নতুন; পরের দিনগুলোতে নতুন ধরি না
      final fresh = d == 0 ? feed.items.where((i) => !reported.contains(i.url)).map((i) => i.url).toSet() : <String>{};
      final m = _compose(feed.items, fresh, day);
      msgs.add((when: when, title: m.head, body: m.short, big: m.big));
    }
    await NotificationService.scheduleRadarAlarms(msgs);
  }
}
