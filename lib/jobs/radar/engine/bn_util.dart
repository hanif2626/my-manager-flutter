// বাংলা অঙ্ক/মাস/তারিখ সহায়ক (ইঞ্জিনের জন্য; সব তারিখ UTC-মধ্যরাত রূপে)।
const _bn = '০১২৩৪৫৬৭৮৯';

String toEn(String s) => s.replaceAllMapped(RegExp('[০-৯]'), (m) => _bn.indexOf(m[0]!).toString());

String toBnStr(Object? s) =>
    s.toString().replaceAllMapped(RegExp('[0-9]'), (m) => _bn[int.parse(m[0]!)]);

const monthsMap = <String, int>{
  'জানুয়ারি': 1, 'জানুয়ারী': 1, 'ফেব্রুয়ারি': 2, 'ফেব্রুয়ারী': 2, 'মার্চ': 3, 'এপ্রিল': 4, 'মে': 5,
  'জুন': 6, 'জুলাই': 7, 'আগস্ট': 8, 'সেপ্টেম্বর': 9, 'অক্টোবর': 10, 'নভেম্বর': 11, 'ডিসেম্বর': 12,
  'january': 1, 'february': 2, 'march': 3, 'april': 4, 'may': 5, 'june': 6, 'july': 7,
  'august': 8, 'september': 9, 'october': 10, 'november': 11, 'december': 12,
};
const monthNamesBn = [
  '', 'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন', 'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর',
];

final _monthAlt = monthsMap.keys.join('|');

DateTime ymdUtc(int y, int m, int d) => DateTime.utc(y, m, d);

/// ঢাকার সময়ে আজকের তারিখ (UTC-মধ্যরাত)।
DateTime todayDhaka([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 6));
  return DateTime.utc(t.year, t.month, t.day);
}

int daysBetween(DateTime a, DateTime b) => b.difference(a).inDays;

class FoundDate {
  final DateTime date;
  final int index;
  const FoundDate(this.date, this.index);
}

/// টেক্সট থেকে সব তারিখ (বাংলা/ইংরেজি মাস অথবা dd.mm.yyyy), অবস্থান অনুযায়ী সাজানো।
List<FoundDate> findDates(String text) {
  final t = toEn(text);
  final out = <FoundDate>[];
  final re1 = RegExp('(\\d{1,2})\\s*($_monthAlt)[,\\s]*(\\d{4})', caseSensitive: false);
  bool valid(int y, int mo, int d) =>
      mo >= 1 && mo <= 12 && d >= 1 && d <= DateTime.utc(y, mo + 1, 0).day;
  for (final m in re1.allMatches(t)) {
    final mo = monthsMap[m[2]!.toLowerCase()] ?? monthsMap[m[2]!];
    final y = int.parse(m[3]!), d = int.parse(m[1]!);
    if (mo != null && valid(y, mo, d)) out.add(FoundDate(ymdUtc(y, mo, d), m.start));
  }
  final re2 = RegExp(r'(\d{1,2})[./-](\d{1,2})[./-](\d{4})');
  for (final m in re2.allMatches(t)) {
    final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
    if (valid(y, mo, d)) {
      out.add(FoundDate(ymdUtc(y, mo, d), m.start));
    }
  }
  out.sort((a, b) => a.index.compareTo(b.index));
  return out;
}

String fmtDateBn(DateTime d) => toBnStr('${d.day} ${monthNamesBn[d.month]} ${d.year}');

/// পূর্ণ বছরে বয়স নির্দিষ্ট তারিখে।
int ageAt(DateTime dob, DateTime ref) {
  var age = ref.year - dob.year;
  final m = ref.month - dob.month;
  if (m < 0 || (m == 0 && ref.day < dob.day)) age--;
  return age;
}
