import '../radar_models.dart';
import 'bn_util.dart';
import 'circular_parser.dart';
import 'districts.dart';

/// রাডারের জন্য ব্যবহারকারীর প্রোফাইল।
class RadarProfile {
  final DateTime dob; // UTC-মধ্যরাত
  final int eduRank; // 2..6
  final String eduLabel;
  final String subject;
  final int typingBn;
  final int typingEn;
  final List<String> targetKeywords;
  final List<String> excludeKeywords;
  final String district; // স্থায়ী জেলার কী (districts.dart); খালি = সিলেক্ট করা নেই, এলাকা-যাচাই হবে না
  const RadarProfile({
    required this.dob,
    required this.eduRank,
    required this.eduLabel,
    this.subject = '',
    required this.typingBn,
    required this.typingEn,
    required this.targetKeywords,
    required this.excludeKeywords,
    this.district = '',
  });
}

class EvalResult {
  final bool expired;
  final List<DateTime> deadlines;
  final DateTime? nearest;
  final String org;
  final String method;
  final String fee;
  final List<RadarPost> posts; // শুধু টার্গেট পদগুলো
  final String verdict; // ok | warn | fail | none
  const EvalResult({
    required this.expired,
    required this.deadlines,
    required this.nearest,
    required this.org,
    required this.method,
    required this.fee,
    required this.posts,
    required this.verdict,
  });
}

const _eduLabel = {
  2: 'এসএসসি',
  3: 'এইচএসসি',
  4: 'স্নাতক (পাস)',
  5: 'স্নাতক (সম্মান/অনার্স)',
  6: 'স্নাতকোত্তর',
};

bool _any(List<String> pats, String s) => pats.any((k) => RegExp(k, caseSensitive: false).hasMatch(s));

/// 'yes' | 'shorthand' | 'no'
String postRelevance(String title, RadarProfile p) {
  if (!_any(p.targetKeywords, title)) return 'no';
  if (_any(p.excludeKeywords, title)) return 'shorthand';
  return 'yes';
}

List<DateTime> parseDeadlines(String text) {
  final f = field(text, 'আবেদনের শেষ তারিখ');
  var ds = f.isNotEmpty ? findDates(f) : <FoundDate>[];
  if (ds.isEmpty) {
    final m = RegExp(r'আবেদনের\s*শেষ\s*(?:তারিখ|সময়)[^\n]{0,80}').firstMatch(text);
    if (m != null) ds = findDates(m[0]!);
  }
  return ds.map((d) => d.date).toList();
}

RadarCheck _ok(String k, String m) => RadarCheck(key: k, s: 'ok', msg: m);
RadarCheck _warn(String k, String m) => RadarCheck(key: k, s: 'warn', msg: m);
RadarCheck _fail(String k, String m) => RadarCheck(key: k, s: 'fail', msg: m);

/// এলাকা-শর্তের সাথে ব্যবহারকারীর জেলা মেলানো। জেলা সিলেক্ট করা না থাকলে বা
/// সার্কুলারে এলাকা-শর্ত না থাকলে null (কোনো যাচাই দেখানো হয় না)।
RadarCheck? areaCheckFor(AreaInfo info, String districtKey) {
  if (districtKey.isEmpty || !info.hasInfo) return null;
  final name = districtByKey(districtKey)?.bn ?? districtKey;
  if (info.excluded.contains(districtKey)) {
    return _fail('area', 'এলাকা: $name জেলা বাদ দেওয়া হয়েছে — আবেদন করা যাবে না');
  }
  if (info.only.isNotEmpty && !info.only.contains(districtKey)) {
    final names = info.only.map((k) => districtByKey(k)?.bn ?? k).toList()..sort();
    final shown = names.length <= 4 ? names.join(', ') : '${names.take(4).join(', ')} ইত্যাদি';
    return _fail('area', 'এলাকা: শুধু $shown জেলার জন্য — তোমার জেলা $name নয়');
  }
  if (info.only.contains(districtKey)) return _ok('area', 'এলাকা: $name জেলার জন্য খোলা');
  if (info.excluded.isNotEmpty) return _ok('area', 'এলাকা: $name জেলা বাদ পড়েনি');
  return _ok('area', 'এলাকা: সকল জেলার জন্য খোলা');
}

/// "সাপ্তাহিক চাকরির খবর" ধরনের সংকলন/পত্রিকা-পোস্ট — আসল সার্কুলার নয়।
final _roundup = RegExp(r'চাকরির\s*খবর|চাকরির\s*ডাক|সাপ্তাহিক|দৈনিক\s*পত্রিকা|পত্রিকা\s*(?:থেকে|সহ)|newspaper|chakrir\s*khobor|saptahik', caseSensitive: false);

/// একটি সার্কুলারের টেক্সট যাচাই। (JS ইঞ্জিনের হুবহু অনুবাদ — একই টেস্টে যাচাই করা)
EvalResult evaluate(String text, RadarProfile profile, {String? title, DateTime? now}) {
  final today = todayDhaka(now);
  if (title != null && _roundup.hasMatch(title)) {
    return const EvalResult(
        expired: false, deadlines: [], nearest: null, org: '', method: '', fee: '', posts: [], verdict: 'none');
  }
  final expiredBanner = RegExp(r'আবেদনের\s*সময়\s*শেষ\s*হয়েছে').hasMatch(text);
  final deadlines = parseDeadlines(text);
  final upcoming = deadlines.where((d) => daysBetween(today, d) >= 0).toList()..sort();
  final nearest = upcoming.isEmpty ? null : upcoming.first;
  final lastDeadline = deadlines.isEmpty ? null : deadlines.last;
  final expired = expiredBanner || (deadlines.isNotEmpty && upcoming.isEmpty);

  final summaryEdu = field(text, 'শিক্ষাগত যোগ্যতা');
  final method = field(text, 'আবেদন পদ্ধতি');
  final fee = field(text, 'আবেদনের ফি');
  final org = field(text, 'প্রতিষ্ঠানের নাম');

  // বয়স — পুরো সার্কুলারের জন্য
  final ageInfo = parseAge(text, lastDeadline);
  RadarCheck ageCheck;
  if (ageInfo == null) {
    ageCheck = _warn('age', 'বয়সসীমা খুঁজে পাইনি — বিজ্ঞপ্তিতে দেখো');
  } else {
    final ref = ageInfo.refDate ?? lastDeadline ?? today;
    final age = ageAt(profile.dob, ref);
    final refTxt = fmtDateBn(ref);
    if (age > ageInfo.max) {
      ageCheck = _fail('age', 'বয়স বেশি: ${toBnStr(age)} বছর (সীমা ${toBnStr(ageInfo.max)}, $refTxt-এর হিসাবে)');
    } else if (ageInfo.min != null && age < ageInfo.min!) {
      ageCheck = _fail('age', 'বয়স কম: ${toBnStr(age)} (ন্যূনতম ${toBnStr(ageInfo.min)})');
    } else {
      ageCheck = _ok('age', 'বয়স ${toBnStr(age)} ≤ ${toBnStr(ageInfo.max)} ($refTxt-এর হিসাবে)');
    }
  }

  var posts = parsePosts(text);
  if (posts.isEmpty && title != null && title.isNotEmpty && postRelevance(title, profile) != 'no') {
    posts = [ParsedPost(title, null, '')];
  }

  // এলাকা — সার্কুলার-জোড়া শর্ত (পদ-ব্লকের বাইরের অংশ থেকে); পদভিত্তিক শর্ত নিচে আলাদা দেখা হয়।
  final circArea = areaCheckFor(parseArea(stripPostBlocks(text)), profile.district);

  final evaluated = <RadarPost>[];
  for (final p in posts) {
    final rel = postRelevance(p.title, profile);
    if (rel == 'no') continue;
    final checks = <RadarCheck>[ageCheck];

    final postArea = p.text.trim().isEmpty ? null : areaCheckFor(parseArea(p.text), profile.district);
    final area = postArea?.s == 'fail' ? postArea : (circArea?.s == 'fail' ? circArea : (postArea ?? circArea));
    if (area != null) checks.add(area);

    if (rel == 'shorthand') {
      evaluated.add(RadarPost(
          title: p.title, count: p.count, verdict: 'fail', checks: [_fail('post', 'সাঁটলিপি/শর্টহ্যান্ড লাগে')]));
      continue;
    }

    final eduText = p.text.trim().isNotEmpty ? p.text : summaryEdu;
    final edu = parseEducation(eduText);
    if (edu.required == null) {
      checks.add(_warn('edu', 'শিক্ষাগত যোগ্যতা পরিষ্কার না — বিজ্ঞপ্তিতে দেখো'));
    } else if (edu.required! > profile.eduRank) {
      checks.add(_fail('edu', '${_eduLabel[edu.required]} চায় — তোমার ${profile.eduLabel}'));
    } else {
      checks.add(_ok('edu', '${_eduLabel[edu.required]} চায় — তোমার ${profile.eduLabel}'));
      if (edu.required! >= 4 &&
          RegExp(r'(বিভাগে|বিষয়ে|সংশ্লিষ্ট\s*বিষয়)').hasMatch(eduText) &&
          profile.subject.isEmpty) {
        checks.add(_warn('subject', 'নির্দিষ্ট বিষয়/বিভাগের শর্ত থাকতে পারে — মিলিয়ে নাও'));
      }
    }
    if (edu.flags.contains('diploma') && edu.required == null) checks.add(_fail('edu', 'ডিপ্লোমা শর্ত আছে'));
    final cls = RegExp(r'(২য়|দ্বিতীয়|১ম|প্রথম)\s*(শ্রেণি|বিভাগ)|সিজিপিএ|CGPA|GPA', caseSensitive: false).firstMatch(eduText);
    if (cls != null) checks.add(_warn('result', 'ফলাফলের শর্ত: "${cls[0]}" — নিজের ফল মিলিয়ে নাও'));

    final typingText = p.text.trim().isNotEmpty ? p.text : text;
    final ty = parseTyping(typingText);
    if (ty.bn == null && ty.en == null) {
      checks.add(_warn('typing', 'টাইপিং গতির উল্লেখ পাইনি'));
    } else {
      final gaps = <String>[];
      if (ty.bn != null && ty.bn! > profile.typingBn) gaps.add('বাংলা ${toBnStr(ty.bn)} (তোমার ${toBnStr(profile.typingBn)})');
      if (ty.en != null && ty.en! > profile.typingEn) gaps.add('ইংরেজি ${toBnStr(ty.en)} (তোমার ${toBnStr(profile.typingEn)})');
      final need = [
        if (ty.bn != null) 'বাংলা ${toBnStr(ty.bn)}',
        if (ty.en != null) 'ইংরেজি ${toBnStr(ty.en)}',
      ].join(', ');
      checks.add(gaps.isNotEmpty
          ? _warn('typing', 'টাইপিং বাড়াতে হবে — ${gaps.join(', ')}')
          : _ok('typing', 'টাইপিং $need WPM — তোমার গতিতে মেলে'));
    }

    final blk = p.text;
    if (RegExp(r'কম্পিউটার[^।\n]{0,60}(সনদ|প্রশিক্ষণ|কোর্স|সার্টিফিকেট|ডিপ্লোমা)').hasMatch(blk)) {
      checks.add(_warn('cert', 'কম্পিউটার সনদ/প্রশিক্ষণের শর্ত আছে'));
    }
    if (RegExp(r'(\d+)\s*বছর(?:ের)?\s*(?:কাজের\s*)?অভিজ্ঞতা|অভিজ্ঞতা[^।\n]{0,20}(\d+)\s*বছর').hasMatch(toEn(blk))) {
      checks.add(_warn('exp', 'অভিজ্ঞতার শর্ত আছে'));
    }

    final verdict = checks.any((c) => c.s == 'fail') ? 'fail' : (checks.any((c) => c.s == 'warn') ? 'warn' : 'ok');
    evaluated.add(RadarPost(title: p.title, count: p.count, verdict: verdict, checks: checks));
  }

  // নিরাপত্তা-জাল: পদ আলাদা করা না গেলেও পেজে টার্গেট শব্দ থাকলে "যাচাই বাকি" — যেন কিছু মিস না হয়।
  // তবে এলাকায় বাদ পড়লে এই জালেও আসবে না (এলাকা fail হলে verdict fail)।
  if (evaluated.isEmpty && _any(profile.targetKeywords, text)) {
    final area = areaCheckFor(parseArea(text), profile.district);
    final checks = <RadarCheck>[
      ageCheck,
      if (area != null) area,
      _warn('parse', 'পেজে কম্পিউটার অপারেটর/ডাটা এন্ট্রি-জাতীয় শব্দ আছে, কিন্তু পদভিত্তিক শর্ত আলাদা করতে পারিনি — মূল বিজ্ঞপ্তি দেখো'),
    ];
    evaluated.add(RadarPost(
      title: (title == null || title.isEmpty) ? 'সার্কুলার' : title,
      verdict: area?.s == 'fail' ? 'fail' : 'warn',
      checks: checks,
    ));
  }

  const rank = {'ok': 0, 'warn': 1, 'fail': 2};
  var verdict = 'none';
  if (evaluated.isNotEmpty) {
    verdict = evaluated.map((e) => e.verdict).reduce((a, b) => rank[a]! <= rank[b]! ? a : b);
  }

  return EvalResult(
    expired: expired,
    deadlines: deadlines,
    nearest: nearest,
    org: org,
    method: method,
    fee: fee,
    posts: evaluated,
    verdict: verdict,
  );
}
