import 'bn_util.dart';
import 'districts.dart';

/// সামারি টেবিলের সারি "লেবেল | মান |" থেকে মান।
String field(String text, String label) {
  final re = RegExp('^$label[^|\\n]*\\|\\s*(.+?)\\s*\\|?\\s*\$', multiLine: true);
  final m = re.firstMatch(text);
  return m == null ? '' : m[1]!.trim();
}

class ParsedPost {
  final String title;
  final int? count;
  final String text; // শর্তের লাইনগুলো
  const ParsedPost(this.title, this.count, this.text);
}

final _postHead = RegExp(r'^(?:##\s*)?(\d+)\s*[.।)]\s*(.+?)\s*\(\s*(\d+)\s*(?:টি|জন)?\s*পদ\s*\)\s*$');
final _tableRow = RegExp(r'^(\d+)\s*\|\s*(.+?)\s*\|\s*(\d+)\s*(?:টি|জন)?\s*\|');

/// পদভিত্তিক ব্লক। না পেলে সামারি টেবিল থেকে শুধু নাম।
List<ParsedPost> parsePosts(String text) {
  final lines = text.split('\n');
  final blocks = <_Block>[];
  _Block? cur;
  for (final raw in lines) {
    final l = toEn(raw);
    final h = _postHead.firstMatch(l);
    if (h != null) {
      cur = _Block(h[2]!.replaceAll('*', '').trim(), int.parse(h[3]!));
      blocks.add(cur);
      continue;
    }
    if (cur != null) {
      if (RegExp(r'^##\s').hasMatch(l)) {
        cur = null; // অন্য হেডিং এলে ব্লক শেষ
      } else {
        cur.lines.add(raw);
      }
    }
  }
  if (blocks.isNotEmpty) {
    return blocks.map((b) => ParsedPost(b.title, b.count, b.lines.join('\n'))).toList();
  }
  final rows = <ParsedPost>[];
  for (final raw in lines) {
    final m = _tableRow.firstMatch(toEn(raw));
    if (m != null) rows.add(ParsedPost(m[2]!.trim(), int.parse(m[3]!), ''));
  }
  return rows;
}

class _Block {
  final String title;
  final int count;
  final List<String> lines = [];
  _Block(this.title, this.count);
}

class Typing {
  final int? bn;
  final int? en;
  const Typing(this.bn, this.en);
}

/// টাইপিং শর্ত (WPM)। ভাষা আলাদা না থাকলে দুটোতেই একই ধরা হয়।
Typing parseTyping(String rawText) {
  final t = toEn(rawText);
  int? num(RegExp re) {
    final m = re.firstMatch(t);
    return m == null ? null : int.parse(m[1]!);
  }

  const tail = r'\s*(?:শব্দ|wpm|ওয়ার্ড|ও(?=\s|$)|এবং|,)';
  var bn = num(RegExp(r'বাংলা(?:য়|তে|র)?[^0-9।]{0,14}?(\d+)' + tail, caseSensitive: false));
  var en = num(RegExp(r'ইংরেজি(?:তে|র)?[^0-9।]{0,14}?(\d+)' + tail, caseSensitive: false));
  if (bn == null && en == null) {
    final g = num(RegExp(r'প্রতি\s*মিনিটে[^0-9।]{0,30}?(\d+)\s*(?:শব্দ|wpm)', caseSensitive: false));
    if (g != null) {
      bn = g;
      en = g;
    }
  }
  return Typing(bn, en);
}

class AgeInfo {
  final int? min;
  final int max;
  final DateTime? refDate;
  const AgeInfo(this.min, this.max, this.refDate);
}

/// বয়সসীমা: ন্যূনতম/সর্বোচ্চ ও গণনার তারিখ।
AgeInfo? parseAge(String rawText, DateTime? fallbackRef) {
  final t = toEn(rawText);
  int? min;
  int? max;
  var idx = -1;
  final r1 = RegExp(r'(\d{1,2})\s*(?:থেকে|[-–])\s*(?:অনুর্ধ্ব|অনূর্ধ্ব|সর্বোচ্চ)?\s*(\d{1,2})\s*বছর');
  final r2 = RegExp(r'(?:অনুর্ধ্ব|অনূর্ধ্ব|সর্বোচ্চ)\s*(\d{1,2})\s*বছর');
  final m1 = r1.firstMatch(t);
  if (m1 != null) {
    min = int.parse(m1[1]!);
    max = int.parse(m1[2]!);
    idx = m1.start;
  } else {
    final m2 = r2.firstMatch(t);
    if (m2 != null) {
      max = int.parse(m2[1]!);
      idx = m2.start;
    }
  }
  if (max == null) return null;
  var ref = fallbackRef;
  final from = (idx - 90) < 0 ? 0 : idx - 90;
  final to = (idx + 5) > t.length ? t.length : idx + 5;
  final before = t.substring(from, to);
  final ds = findDates(before);
  if (ds.isNotEmpty && before.contains('তারিখে')) ref = ds.last.date;
  return AgeInfo(min, max, ref);
}

class EduInfo {
  final int? required; // 2=SSC 3=HSC 4=স্নাতক(পাস) 5=অনার্স 6=মাস্টার্স
  final List<String> flags;
  const EduInfo(this.required, this.flags);
}

EduInfo parseEducation(String rawText) {
  var t = rawText;
  final levels = <int>[];
  final flags = <String>[];
  if (RegExp(r'স্নাতকোত্তর|মাস্টার', caseSensitive: false).hasMatch(t)) levels.add(6);
  t = t.replaceAll(RegExp(r'স্নাতকোত্তর|মাস্টার[স্সz]*', caseSensitive: false), ' ');
  final hon = RegExp(r'স্নাতক\s*\(?\s*সম্মান\s*\)?|সম্মান\s*সহ|অনার্স|honou?rs|চার\s*বছর\s*মেয়াদী', caseSensitive: false);
  final hasHon = hon.hasMatch(t);
  if (hasHon) levels.add(5);
  t = t.replaceAll(hon, ' ');
  final bpass = RegExp(r'স্নাতক\s*\(?\s*পাস\s*\)?|স্নাতক\s*পাস|ডিগ্রি\s*পাস', caseSensitive: false);
  if (bpass.hasMatch(t)) levels.add(4);
  t = t.replaceAll(bpass, ' ');
  if (RegExp(r'স্নাতক|bachelor', caseSensitive: false).hasMatch(t)) levels.add(4);
  if (RegExp(r'এইচ\s*এস\s*সি|উচ্চ\s*মাধ্যমিক|\bhsc\b|ইন্টারমিডিয়েট|আলিম', caseSensitive: false).hasMatch(t)) levels.add(3);
  t = t.replaceAll(RegExp(r'উচ্চ\s*মাধ্যমিক'), ' ');
  if (RegExp(r'এস\s*এস\s*সি|মাধ্যমিক|\bssc\b|দাখিল', caseSensitive: false).hasMatch(t)) levels.add(2);
  // শুধু "ডিগ্রি" লেখা থাকলে (স্নাতক শব্দ ছাড়া) সেটাকেও স্নাতক ধরি
  if (levels.isEmpty && t.contains('ডিগ্রি') && !t.contains('ডিপ্লোমা')) levels.add(4);
  if (rawText.contains('ডিপ্লোমা')) flags.add('diploma');
  int? required;
  if (levels.isNotEmpty) required = levels.reduce((a, b) => a < b ? a : b);
  return EduInfo(required, flags);
}

/// পদভিত্তিক ব্লক বাদ দিয়ে বাকি টেক্সট (সামারি + সাধারণ শর্ত) — সার্কুলার-জোড়া শর্ত
/// (যেমন এলাকা) পদ-ব্লকের শর্তের সাথে গুলিয়ে ফেলা ঠেকাতে। ব্লক না থাকলে পুরো টেক্সটই।
String stripPostBlocks(String text) {
  final out = <String>[];
  var inBlock = false;
  var sawBlock = false;
  for (final raw in text.split('\n')) {
    final l = toEn(raw);
    if (_postHead.hasMatch(l)) {
      inBlock = true;
      sawBlock = true;
      continue;
    }
    if (inBlock && RegExp(r'^##\s').hasMatch(l)) inBlock = false;
    if (!inBlock) out.add(raw);
  }
  return sawBlock ? out.join('\n') : text;
}

// ── এলাকা-শর্ত ──

/// সার্কুলারের এলাকা-শর্ত: কোন জেলা বাদ, কোন জেলার জন্যই শুধু, নাকি সকল জেলার জন্য খোলা।
class AreaInfo {
  final Set<String> excluded; // বাদ দেওয়া জেলার কী
  final Set<String> only; // শুধু এই জেলাগুলোর জন্য (খালি = এমন শর্ত পাওয়া যায়নি)
  final bool allOpen; // "সকল জেলা" বলা আছে
  const AreaInfo(this.excluded, this.only, this.allOpen);
  bool get hasInfo => excluded.isNotEmpty || only.isNotEmpty || allOpen;
}

final _exclMark = RegExp(
    r'ব্যতীত|বাদে|ছাড়া|ব্যতিরেকে|আবেদন\s*করতে\s*পারবেন\s*না|আবেদন\s*করতে\s*পারবে\s*না|যোগ্য\s*নন|যোগ্য\s*হবেন\s*না|প্রযোজ্য\s*নয়|except|excluding',
    caseSensitive: false);
final _exclFlip = RegExp(r'(ব্যতীত|বাদে|ছাড়া)\s*(অন্য|অন্যান্য|আর\s*কোনো|আর\s*কেউ)');
final _onlyWord = RegExp(r'শুধু|শুধুমাত্র|কেবল|কেবলমাত্র|\bonly\b', caseSensitive: false);
final _resident = RegExp(r'স্থায়ী\s*বাসিন্দা|স্থায়ীভাবে\s*বসবাস|permanent\s*resident', caseSensitive: false);
final _eligibleVerb = RegExp(r'আবেদন\s*করতে\s*পারবেন|আবেদন\s*করতে\s*পারবে|আবেদনের\s*যোগ্য|আবেদন\s*করিতে\s*পারিবেন');
final _mustBe = RegExp(r'হতে\s*হবে|হইতে\s*হইবে');
final _allOpenRe = RegExp(r'সকল\s*জেলা|সব\s*জেলা|সমগ্র\s*বাংলাদেশ|সারাদেশ|সারা\s*দেশ|all\s*districts', caseSensitive: false);
final _areaCtx = RegExp(r'জেলা|প্রার্থী|আবেদন|বাসিন্দা|যোগ্য|district', caseSensitive: false);

/// টেক্সট থেকে এলাকা-শর্ত। শুধু স্পষ্ট শর্তেই ধরে — জেলার নাম থাকলেই নয়
/// (যেমন "ঢাকায় পরীক্ষা হবে" এলাকা-শর্ত নয়)। বাক্য ধরে ধরে দেখা হয়।
AreaInfo parseArea(String rawText) {
  final excluded = <String>{};
  final only = <String>{};
  var allOpen = false;
  for (final seg in rawText.split(RegExp(r'[\n।;]'))) {
    final s = seg.trim();
    if (s.isEmpty) continue;
    // "রাজশাহী বিভাগ" থাকলে সেটা বিভাগের শর্ত — জেলা খোঁজার আগে ওই অংশ সরিয়ে নিই,
    // নইলে বিভাগের নামের জেলাটা একাই ধরা পড়ত।
    final divs = divisionsIn(s);
    var rest = s;
    for (final d in divs) {
      rest = rest.replaceAll(RegExp('${RegExp.escape(d.bn)}\\s*বিভাগ'), ' ');
      rest = rest.replaceAll(RegExp(r'\b' + RegExp.escape(d.en) + r'\s+division\b', caseSensitive: false), ' ');
    }
    final named = <String>{
      ...districtsIn(rest),
      for (final d in divs) ...districtsOfDivision(d.key),
    };
    final segAllOpen = _allOpenRe.hasMatch(s);
    if (segAllOpen && divs.isEmpty) allOpen = true;
    if (_exclMark.hasMatch(s) && _areaCtx.hasMatch(s)) {
      if (s.contains('পার্বত্য')) excluded.addAll(hillDistricts);
      // "ঢাকা জেলার প্রার্থী ব্যতীত অন্যরা আবেদন করতে পারবেন না" মানে শুধু ঢাকা — বাদ নয়।
      if (_exclFlip.hasMatch(s)) {
        only.addAll(named);
      } else {
        excluded.addAll(named);
      }
      continue;
    }
    if (named.isEmpty) continue;
    final hasOnly = _onlyWord.hasMatch(s);
    final hasRes = _resident.hasMatch(s);
    final hasVerb = _eligibleVerb.hasMatch(s);
    if (hasOnly && (hasRes || hasVerb || s.contains('জেলা') || divs.isNotEmpty)) {
      only.addAll(named);
    } else if (hasRes && (hasVerb || _mustBe.hasMatch(s))) {
      only.addAll(named);
    } else if (hasVerb && divs.isNotEmpty) {
      only.addAll(named);
    } else if (hasVerb && !segAllOpen && (s.contains('জেলার') || s.contains('জেলাসমূহের'))) {
      only.addAll(named);
    }
  }
  only.removeAll(excluded); // একই জেলা দুই তালিকায় থাকলে "বাদ"ই জেতে
  return AreaInfo(excluded, only, allOpen);
}
