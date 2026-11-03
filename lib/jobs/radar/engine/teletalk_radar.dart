import '../radar_models.dart';
import 'bn_util.dart';
import 'match_engine.dart';
import 'teletalk_source.dart';

/// তালিকা থেকে আমাদের টার্গেট পদগুলো (মেয়াদ বাকি, সাঁটলিপি নয়)।
List<TeletalkJob> pickTeletalkTargets(List<TeletalkJob> jobs, RadarProfile profile, {DateTime? now}) {
  final today = todayDhaka(now);
  return jobs.where((j) {
    if (j.deadline != null && daysBetween(today, j.deadline!) < 0) return false;
    return postRelevance('${j.titleBn} ${j.titleEn}', profile) == 'yes';
  }).toList();
}

/// বিস্তারিত API-র বয়সসীমা দিয়ে বয়স যাচাই। রেফারেন্স তারিখ = শেষ তারিখ (মূল বিজ্ঞপ্তিতে গণনার তারিখ দেখে নিও)।
RadarCheck? teletalkAgeCheck(TeletalkJob j, TeletalkDetail? d, RadarProfile profile) {
  if (d == null || d.maxAge == null) return null;
  final ref = j.deadline ?? todayDhaka();
  final age = ageAt(profile.dob, ref);
  final refTxt = fmtDateBn(ref);
  if (age > d.maxAge!) {
    return RadarCheck(key: 'age', s: 'fail', msg: 'বয়স বেশি: ${toBnStr(age)} বছর (সীমা ${toBnStr(d.maxAge)}, $refTxt-এর হিসাবে)');
  }
  if (d.minAge != null && age < d.minAge!) {
    return RadarCheck(key: 'age', s: 'fail', msg: 'বয়স কম: ${toBnStr(age)} (ন্যূনতম ${toBnStr(d.minAge)})');
  }
  return RadarCheck(key: 'age', s: 'ok', msg: 'বয়স ${toBnStr(age)} ≤ ${toBnStr(d.maxAge)} ($refTxt-এর হিসাবে — মূল বিজ্ঞপ্তিতে গণনার তারিখ দেখো)');
}

/// টার্গেট পদগুলো বেছে একই প্রতিষ্ঠানের পদ একসাথে করে RadarItem বানায়।
///
/// [details] থাকলে বয়স স্বয়ংক্রিয় যাচাই হয় (বয়সে না মিললে পদটা বাদ)। শিক্ষা ও টাইপিংয়ের শর্ত শুধু
/// বিজ্ঞপ্তির PDF-এ থাকে, তাই কার্ড সবসময় "যাচাই বাকি" (🟡) — PDF দেখে নিশ্চিত হতে হবে।
List<RadarItem> teletalkItems(
  List<TeletalkJob> jobs,
  RadarProfile profile, {
  DateTime? now,
  Map<int, TeletalkDetail> details = const {},
}) {
  final today = todayDhaka(now);
  final groups = <String, List<TeletalkJob>>{};
  for (final j in pickTeletalkTargets(jobs, profile, now: now)) {
    final key = j.applyUrl.isNotEmpty ? j.applyUrl : j.shortName;
    groups.putIfAbsent(key, () => []).add(j);
  }

  final items = <RadarItem>[];
  groups.forEach((key, list) {
    list.sort((a, b) => a.primaryId.compareTo(b.primaryId));
    final first = list.first;
    final org = first.orgNameBn.isNotEmpty ? first.orgNameBn : first.orgName;

    final posts = <RadarPost>[];
    final usable = <TeletalkJob>[];
    for (final j in list) {
      final d = details[j.primaryId];
      final age = teletalkAgeCheck(j, d, profile);
      if (age != null && age.s == 'fail') continue; // বয়সে মেলেনি — কার্ডে আনি না

      final checks = <RadarCheck>[
        RadarCheck(key: 'post', s: 'ok', msg: 'পদের নাম মিলেছে: ${j.titleEn}'),
        if (age != null) age else const RadarCheck(key: 'age', s: 'warn', msg: 'বয়সসীমা আনা যায়নি — বিজ্ঞপ্তিতে দেখো'),
      ];
      if (j.published != null && daysBetween(today, j.published!) > 0) {
        checks.add(RadarCheck(key: 'start', s: 'warn', msg: 'আবেদন শুরু: ${fmtDateBn(j.published!)} (এখনো শুরু হয়নি)'));
      }
      checks.add(const RadarCheck(
        key: 'details',
        s: 'warn',
        msg: 'শিক্ষা ও টাইপিংয়ের শর্ত বিজ্ঞপ্তির PDF-এ দেখো — এখনো স্বয়ংক্রিয় যাচাই হয়নি',
      ));
      if (d != null && d.adNo.isNotEmpty) {
        checks.add(RadarCheck(key: 'adno', s: 'ok', msg: 'বিজ্ঞপ্তি নং: ${d.adNo}'));
      }
      posts.add(RadarPost(
        title: j.titleBn.isNotEmpty ? j.titleBn : j.titleEn,
        count: j.vacancy,
        verdict: 'warn',
        checks: checks,
      ));
      usable.add(j);
    }
    if (posts.isEmpty) return;

    final deadlines = usable.map((j) => j.deadline).whereType<DateTime>().toList()..sort();
    final dl = deadlines.isEmpty ? null : deadlines.first;
    final starts = usable.map((j) => j.published).whereType<DateTime>().toList()..sort();
    final st = starts.isEmpty ? null : starts.first;
    final adNo = usable
        .map((j) => details[j.primaryId]?.adNo ?? '')
        .firstWhere((a) => a.isNotEmpty, orElse: () => '');
    final adFile = usable
        .map((j) => details[j.primaryId]?.adFile ?? '')
        .firstWhere((a) => a.isNotEmpty, orElse: () => '');
    items.add(RadarItem(
      // Teletalk-এ এই প্রতিষ্ঠানের বিস্তারিত পেজ; #teletalk যোগ করে bdgovtjob-এর লিংকের সাথে মিশে যাওয়া ঠেকানো
      url: '${first.detailsUrl}#teletalk',
      title: '$org (Teletalk)',
      verdict: 'warn',
      org: org,
      deadline: dl == null ? null : DateTime(dl.year, dl.month, dl.day),
      method: 'অনলাইন — ${first.applyUrl}',
      posts: posts,
      published: st == null ? null : DateTime(st.year, st.month, st.day),
      adNo: adNo,
      source: 'teletalk',
      adFile: adFile,
      applyUrl: first.applyUrl,
    ));
  });
  return items;
}
