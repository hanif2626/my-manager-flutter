import 'package:flutter_test/flutter_test.dart';
import 'package:my_manager/jobs/radar/engine/bn_util.dart';
import 'package:my_manager/jobs/radar/engine/circular_parser.dart';
import 'package:my_manager/jobs/radar/engine/html_text.dart';
import 'package:my_manager/jobs/radar/engine/match_engine.dart';

// JS ইঞ্জিনের টেস্টের হুবহু অনুবাদ — একই ইনপুটে একই ফল আসা উচিত।
final profile = RadarProfile(
  dob: DateTime.utc(1999, 1, 1),
  eduRank: 4,
  eduLabel: 'স্নাতক (পাস কোর্স, ৩ বছর)',
  typingBn: 20,
  typingEn: 20,
  targetKeywords: const [
    r'কম্পিউটার\s*অপারেটর', r'কম্পিউটার\s*মুদ্রাক্ষরিক', r'ডাটা\s*এন্ট্রি', r'ডেটা\s*এন্ট্রি',
    r'ডাটা\s*অপারেটর', r'ডেটা\s*অপারেটর', r'অফিস\s*সহায়ক\s*[-–]?\s*কাম',
    r'computer\s*operator', r'data\s*entry', r'computer\s*typist',
  ],
  excludeKeywords: const ['সাঁট', 'সীট', 'শর্টহ্যান্ড', 'stenograph', 'shorthand'],
);

final july15 = DateTime.utc(2026, 7, 15, 6);
final oct13 = DateTime.utc(2026, 10, 13, 6);

const planning = '''<article><h1>বাংলাদেশ পরিকল্পনা কমিশন নিয়োগ বিজ্ঞপ্তি ২০২৬</h1>
<h2>এক নজরে জব সামারি</h2>
<table><tr><td>প্রতিষ্ঠানের নাম</td><td>বাংলাদেশ পরিকল্পনা কমিশন</td></tr>
<tr><td>বয়সসীমা</td><td>১৮-৩২ বছর</td></tr>
<tr><td>শিক্ষাগত যোগ্যতা</td><td>এইচএসসি পাশ</td></tr>
<tr><td>আবেদনের ফি</td><td>১০০/- টাকা</td></tr>
<tr><td>আবেদনের শেষ তারিখ</td><td>৩০ জুলাই ২০২৬ অফিস চলাকালীন সময় পর্যন্ত</td></tr>
<tr><td>আবেদন পদ্ধতি</td><td>অফলাইন/ডাকযোগে</td></tr></table>
<h2>পদের সংক্ষিপ্ত বিবরণ</h2>
<table><tr><td>ক্রমিক</td><td>পদের নাম</td><td>পদ সংখ্যা</td></tr><tr><td>১</td><td>ডাটা এন্ট্রি অপারেটর</td><td>১টি</td><td>গ্রেড-১৪</td></tr></table>
<h2>বাংলাদেশ পরিকল্পনা কমিশন পদভিত্তিক শিক্ষাগত যোগ্যতা ও অভিজ্ঞতা</h2>
<p><strong>১. ডাটা এন্ট্রি অপারেটর (১ টি পদ)</strong></p><p>শিক্ষাগত যোগ্যতা:</p>
<ul><li>কোনো স্বীকৃত বোর্ড হতে উচ্চ মাধ্যমিক সার্টিফিকেট (এইচএসসি) বা সমমানের পরীক্ষায় উত্তীর্ণ হতে হবে।</li>
<li>কম্পিউটার মুদ্রাক্ষরে প্রতি মিনিটে বাংলায় ২০ শব্দ এবং ইংরেজিতে ২০ শব্দের গতিসহ সংশ্লিষ্ট বিষয়ে Standard Aptitude Test এ উত্তীর্ণ হতে হবে।</li></ul>
<h2>আবেদনের বয়সসীমা (Age Limit)</h2>
<p>এই বিজ্ঞপ্তিতে আবেদনের জন্য প্রার্থীদের বয়স <strong>৩০ জুলাই ২০২৬ তারিখে ১৮ থেকে অনুর্ধ্ব ৩২ বছরের</strong> মধ্যে হতে হবে।</p>
</article>''';

const multi = '''<h2>এক নজরে</h2><table><tr><td>প্রতিষ্ঠানের নাম</td><td>কর অঞ্চল</td></tr>
<tr><td>আবেদনের শেষ তারিখ</td><td>৩ নভেম্বর ২০২৬</td></tr></table>
<h2>পদভিত্তিক যোগ্যতা</h2>
<h3>১. সীট-মুদ্রাক্ষরিক কাম-কম্পিউটার অপারেটর (১০ টি পদ)</h3>
<p>স্নাতক। সাঁটলিপিতে ইংরেজি ৭০ ও বাংলা ৪৫ শব্দ গতি।</p>
<h3>২. কম্পিউটার অপারেটর (৩ টি পদ)</h3>
<p>স্বীকৃত বিশ্ববিদ্যালয় থেকে বিজ্ঞান বিভাগে স্নাতক (সম্মান) বা সমমানের ডিগ্রি।</p>
<h3>৩. অফিস সহকারী কাম-কম্পিউটার মুদ্রাক্ষরিক (৮ টি পদ)</h3>
<p>এইচএসসি বা সমমান। কম্পিউটারে বাংলায় ২৫ শব্দ ও ইংরেজিতে ৩০ শব্দ গতি থাকতে হবে।</p>
<h3>৪. অফিস সহায়ক (২০ টি পদ)</h3><p>এসএসসি বা সমমান।</p>
<h2>বয়সসীমা</h2><p>০১.০৯.২০২৬ তারিখে ১৮-৩২ বছর</p>''';

void main() {
  roundupTests();
  areaTests();
  test('পরিকল্পনা কমিশন: ডাটা এন্ট্রি, HSC, ২০/২০ → সম্ভাব্য যোগ্য', () {
    final r = evaluate(htmlToText(planning), profile, now: july15, title: 'পরিকল্পনা কমিশন');
    expect(r.expired, false);
    expect(r.verdict, 'ok');
    expect(r.posts.length, 1);
    expect(daysBetween(todayDhaka(july15), r.nearest!), 15);
    expect(r.method.contains('অফলাইন'), true);
  });

  test('শেষ তারিখ পার হলে মেয়াদোত্তীর্ণ', () {
    final r = evaluate(htmlToText(planning), profile, now: oct13);
    expect(r.expired, true);
  });

  test('বহু-পদ: সাঁটলিপি ❌, অনার্স ❌, মুদ্রাক্ষরিক ⚠️, অফিস সহায়ক বাদ', () {
    final r = evaluate(htmlToText(multi), profile, now: oct13);
    expect(r.posts.length, 3);
    final by = {for (final p in r.posts) p.title: p};
    expect(by['সীট-মুদ্রাক্ষরিক কাম-কম্পিউটার অপারেটর']!.verdict, 'fail');
    expect(by['কম্পিউটার অপারেটর']!.verdict, 'fail');
    expect(by['কম্পিউটার অপারেটর']!.checks.firstWhere((c) => c.key == 'edu').msg.contains('সম্মান'), true);
    final m = by['অফিস সহকারী কাম-কম্পিউটার মুদ্রাক্ষরিক']!;
    expect(m.verdict, 'warn');
    expect(RegExp('বাংলা ২৫.*ইংরেজি ৩০').hasMatch(m.checks.firstWhere((c) => c.key == 'typing').msg), true);
    expect(r.verdict, 'warn');
  });

  test('বয়স বেশি হলে ❌', () {
    final old = RadarProfile(
      dob: DateTime.utc(1990, 1, 1), eduRank: 4, eduLabel: 'স্নাতক', typingBn: 20, typingEn: 20,
      targetKeywords: profile.targetKeywords, excludeKeywords: profile.excludeKeywords,
    );
    expect(evaluate(htmlToText(planning), old, now: july15).verdict, 'fail');
  });

  test('পদ আলাদা করা না গেলেও কীওয়ার্ড থাকলে ⚠️', () {
    expect(evaluate('আজকের নিয়োগ\nকম্পিউটার অপারেটর পদে লোক নেওয়া হবে।', profile, now: oct13).verdict, 'warn');
  });

  test('অপ্রাসঙ্গিক সার্কুলার → none', () {
    expect(evaluate('পুলিশ কনস্টেবল নিয়োগ\n১. কনস্টেবল (১০০ টি পদ)\nএইচএসসি', profile, now: oct13).verdict, 'none');
  });

  test('শিক্ষাগত যোগ্যতা পার্সার', () {
    expect(parseEducation('স্নাতক (সম্মান) বা সমমানের ডিগ্রি').required, 5);
    expect(parseEducation('স্নাতক বা সমমান').required, 4);
    expect(parseEducation('স্নাতক (পাস) / স্নাতক (সম্মান)').required, 4);
    expect(parseEducation('উচ্চ মাধ্যমিক সার্টিফিকেট (এইচএসসি) বা সমমান').required, 3);
    expect(parseEducation('এসএসসি পাস').required, 2);
    expect(parseEducation('স্নাতকোত্তর ডিগ্রি').required, 6);
  });

  test('টাইপিং ও বয়স পার্সার', () {
    var t = parseTyping('বাংলায় ২০ শব্দ এবং ইংরেজিতে ২০ শব্দের গতি');
    expect([t.bn, t.en], [20, 20]);
    t = parseTyping('ইংরেজি ৩০ ও বাংলা ২৫ শব্দ');
    expect([t.bn, t.en], [25, 30]);
    t = parseTyping('প্রতি মিনিটে ২৫ শব্দ');
    expect([t.bn, t.en], [25, 25]);
    final a = parseAge('০১.০৯.২০২৬ তারিখে ১৮-৩২ বছর', null)!;
    expect(a.max, 32);
    expect(a.min, 18);
    expect(a.refDate, DateTime.utc(2026, 9, 1));
  });
}

void roundupTests() {
  test('সাপ্তাহিক চাকরির খবর সংকলন → none (ভুল ধরা পড়ে না)', () {
    final r = evaluate('কম্পিউটার অপারেটর ... অনেক বিজ্ঞপ্তির তালিকা', profile,
        now: oct13, title: 'সাপ্তাহিক চাকরির খবর পত্রিকা ১৬ অক্টোবর ২০২৬ PDF সহ | Saptahik Chakrir Khobor 2026');
    expect(r.verdict, 'none');
  });
}

// ── এলাকা-শর্ত: স্থায়ী জেলা জয়পুরহাট ──

final profileJ = RadarProfile(
  dob: DateTime.utc(1999, 1, 1),
  eduRank: 4,
  eduLabel: 'স্নাতক (পাস কোর্স, ৩ বছর)',
  typingBn: 20,
  typingEn: 20,
  targetKeywords: profile.targetKeywords,
  excludeKeywords: profile.excludeKeywords,
  district: 'joypurhat',
);

String _circ(String areaLine) => '''এক নজরে
প্রতিষ্ঠানের নাম | পরীক্ষা অফিস |
আবেদনের শেষ তারিখ | ৩০ নভেম্বর ২০২৬ |
১. কম্পিউটার অপারেটর (৫ টি পদ)
এইচএসসি পাশ। বাংলায় ২০ শব্দ ও ইংরেজিতে ২০ শব্দ গতি।
শর্ত: $areaLine
বয়স: ০১.০৯.২০২৬ তারিখে ১৮-৩২ বছর''';

void areaTests() {
  test('এলাকা পার্সার: বাদ/শুধু/সকল', () {
    var a = parseArea('রাজশাহী, নাটোর ও পাবনা জেলার প্রার্থীগণ আবেদন করতে পারবেন না।');
    expect(a.excluded, {'rajshahi', 'natore', 'pabna'});
    a = parseArea('শুধুমাত্র ঢাকা জেলার স্থায়ী বাসিন্দাগণ আবেদন করতে পারবেন।');
    expect(a.only, {'dhaka'});
    a = parseArea('সকল জেলার প্রার্থীগণ আবেদন করতে পারবেন।');
    expect(a.allOpen, true);
    expect(a.only.isEmpty, true);
    a = parseArea('ঢাকা জেলার প্রার্থীগণ ব্যতীত অন্য কোনো জেলার প্রার্থী আবেদন করতে পারবেন না।');
    expect(a.only, {'dhaka'});
    expect(a.excluded.isEmpty, true);
    a = parseArea('পার্বত্য জেলাসমূহ ব্যতীত সকল জেলার প্রার্থীগণ আবেদন করতে পারবেন।');
    expect(a.excluded, {'bandarban', 'rangamati', 'khagrachhari'});
    a = parseArea('পরীক্ষা ঢাকায় অনুষ্ঠিত হবে।');
    expect(a.hasInfo, false);
  });

  test('শুধু অন্য জেলার সার্কুলার → fail (সামনে আসবে না)', () {
    final r = evaluate(_circ('শুধুমাত্র ঢাকা জেলার স্থায়ী বাসিন্দাগণ আবেদন করতে পারবেন।'), profileJ, now: oct13);
    expect(r.verdict, 'fail');
    expect(r.posts.first.checks.firstWhere((c) => c.key == 'area').s, 'fail');
  });

  test('নিজের জেলা বাদ দেওয়া সার্কুলার → fail', () {
    final r = evaluate(_circ('জয়পুরহাট জেলা ব্যতীত সকল জেলার প্রার্থীগণ আবেদন করতে পারবেন।'), profileJ, now: oct13);
    expect(r.verdict, 'fail');
  });

  test('সকল জেলার সার্কুলার → এলাকায় ✅', () {
    final r = evaluate(_circ('সকল জেলার প্রার্থীগণ আবেদন করতে পারবেন।'), profileJ, now: oct13);
    expect(r.verdict, isNot('fail'));
    expect(r.posts.first.checks.firstWhere((c) => c.key == 'area').s, 'ok');
  });

  test('নিজের বিভাগের সার্কুলার → এলাকায় ✅', () {
    final r = evaluate(_circ('শুধু রাজশাহী বিভাগের জেলাসমূহের প্রার্থীগণ আবেদন করতে পারবেন।'), profileJ, now: oct13);
    expect(r.verdict, isNot('fail'));
    expect(r.posts.first.checks.firstWhere((c) => c.key == 'area').s, 'ok');
  });

  test('জেলা সিলেক্ট করা না থাকলে এলাকা-যাচাই নেই', () {
    final r = evaluate(_circ('শুধুমাত্র ঢাকা জেলার স্থায়ী বাসিন্দাগণ আবেদন করতে পারবেন।'), profile, now: oct13);
    expect(r.posts.first.checks.any((c) => c.key == 'area'), false);
  });
}
