import '../radar_models.dart';

/// একই সার্কুলার একাধিক উৎসে (bdgovtjob + Teletalk) থাকলে এক কার্ডে জোড়া লাগায়।
///
/// মিল ধরা হয় যখন: প্রতিষ্ঠান একই (নামের একটা অন্যটার ভেতরে পড়ে) এবং
///   (অন্তত একটা পদের নাম মেলে অথবা শেষ তারিখ একই)।
/// জোড়া কার্ডে: Teletalk থেকে সরকারি পদসংখ্যা/তারিখ/বিজ্ঞপ্তি নং/বয়স, আর bdgovtjob থেকে
/// শিক্ষা-টাইপিংসহ বিস্তারিত যাচাই — দুটোর সেরা অংশ। অন্য উৎসের লিংক [RadarItem.altUrls]-এ থাকে।
List<RadarItem> mergeDuplicates(List<RadarItem> items) {
  final groups = <List<RadarItem>>[];
  for (final it in items) {
    List<RadarItem>? home;
    for (final g in groups) {
      if (g.any((o) => _same(o, it))) {
        home = g;
        break;
      }
    }
    if (home != null) {
      home.add(it);
    } else {
      groups.add([it]);
    }
  }
  return groups.map(_mergeGroup).toList();
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'teletalk'), '').replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true), '');

bool _contains(String a, String b, {int min = 6}) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  return shorter.length >= min && longer.contains(shorter);
}

String _orgKey(RadarItem i) => _norm(i.org.isNotEmpty ? i.org : i.title);

bool _same(RadarItem a, RadarItem b) {
  if (a.url == b.url) return true;
  if (!_contains(_orgKey(a), _orgKey(b), min: 8)) return false;
  if (a.deadline != null && b.deadline != null && a.deadline == b.deadline) return true;
  for (final pa in a.posts) {
    for (final pb in b.posts) {
      if (_contains(_norm(pa.title), _norm(pb.title))) return true;
    }
  }
  return false;
}

RadarItem _mergeGroup(List<RadarItem> g) {
  if (g.length == 1) return g.first;
  // Teletalk আগে — সরকারি উৎস, তাই মূল (primary) এটাই
  final ordered = [...g]..sort((a, b) => (b.source == 'teletalk' ? 1 : 0).compareTo(a.source == 'teletalk' ? 1 : 0));
  final primary = ordered.first;

  final posts = <RadarPost>[];
  final fromTele = <bool>[];
  for (final it in ordered) {
    final tele = it.source == 'teletalk';
    for (final p in it.posts) {
      final idx = posts.indexWhere((q) => _contains(_norm(q.title), _norm(p.title)));
      if (idx < 0) {
        posts.add(p);
        fromTele.add(tele);
      } else if (fromTele[idx] && !tele) {
        posts[idx] = _mergePost(posts[idx], p);
        fromTele[idx] = false; // এখন আর শুধু Teletalk নয়
      } else if (posts[idx].count == null && p.count != null) {
        posts[idx] = RadarPost(title: posts[idx].title, count: p.count, verdict: posts[idx].verdict, checks: posts[idx].checks);
      }
    }
  }

  RadarItem? web;
  for (final it in ordered) {
    if (it.source != 'teletalk') {
      web = it;
      break;
    }
  }

  DateTime? pick(DateTime? a, DateTime? b) => a ?? b;
  final others = ordered.skip(1).map((e) => e.url).where((u) => u != primary.url).toSet().toList();
  return RadarItem(
    url: primary.url,
    title: primary.title,
    // শিক্ষা/টাইপিং যাচাই শুধু web-এ হয়; সেটাই চূড়ান্ত মত (না থাকলে primary-র)
    verdict: web != null ? web.verdict : primary.verdict,
    org: primary.org.isNotEmpty ? primary.org : (web?.org ?? ''),
    deadline: pick(primary.deadline, web?.deadline),
    method: (web?.method.isNotEmpty ?? false) ? web!.method : primary.method,
    fee: (web?.fee.isNotEmpty ?? false) ? web!.fee : primary.fee,
    posts: posts,
    published: ordered.map((e) => e.published).whereType<DateTime>().fold<DateTime?>(null, (p, e) => p ?? e),
    adNo: ordered.map((e) => e.adNo).firstWhere((a) => a.isNotEmpty, orElse: () => ''),
    source: 'merged',
    altUrls: others,
    adFile: ordered.map((e) => e.adFile).firstWhere((a) => a.isNotEmpty, orElse: () => ''),
    applyUrl: ordered.map((e) => e.applyUrl).firstWhere((a) => a.isNotEmpty, orElse: () => ''),
  );
}

/// [tele] = Teletalk-এর পদ, [web] = bdgovtjob-এর যাচাই-করা পদ। দুটোর সেরা অংশ নিয়ে একটা পদ।
RadarPost _mergePost(RadarPost tele, RadarPost web) {
  final checks = <RadarCheck>[...web.checks];
  final keys = web.checks.map((c) => c.key).toSet();
  for (final c in tele.checks) {
    if (c.key == 'details' || c.key == 'post') continue; // web-এ এগুলো আরও ভালোভাবে যাচাই হয়েছে
    if (c.key == 'age') {
      // web-এ বয়স না থাকলে বা অনিশ্চিত (warn) থাকলে Teletalk-এর নির্দিষ্ট সীমা বসাই
      final i = checks.indexWhere((x) => x.key == 'age');
      if (i < 0) {
        checks.add(c);
      } else if (checks[i].s == 'warn' && c.s != 'warn') {
        checks[i] = c;
      }
      continue;
    }
    if (!keys.contains(c.key)) checks.add(c);
  }
  return RadarPost(
    title: web.title.length >= tele.title.length ? web.title : tele.title,
    count: tele.count ?? web.count,
    verdict: web.verdict,
    checks: checks,
  );
}
