import '../../reminder/models/reminder.dart';

const memberRelations = [
  'নিজে', 'স্ত্রী', 'স্বামী', 'বাবা', 'মা', 'ছেলে', 'মেয়ে',
  'ভাই', 'বোন', 'দাদা/দাদি', 'নানা/নানি', 'অন্যান্য',
];

const bloodGroups = ['A+', 'A-', 'B+', 'B-', 'O+', 'O-', 'AB+', 'AB-'];

/// বিলের ধরন → (ইমোজি, নাম)
const billTypes = <String, (String, String)>{
  'rent': ('🏠', 'বাসা ভাড়া'),
  'electric': ('💡', 'বিদ্যুৎ'),
  'gas': ('🔥', 'গ্যাস'),
  'water': ('🚰', 'পানি'),
  'internet': ('🌐', 'ইন্টারনেট'),
  'fee': ('🎓', 'ফি'),
  'installment': ('💳', 'কিস্তি'),
  'other': ('🧾', 'অন্যান্য'),
};

/// জরুরি তথ্যের ধরন → (ইমোজি, নাম)
const contactKinds = <String, (String, String)>{
  'emergency': ('🚨', 'জরুরি নম্বর'),
  'doctor': ('🩺', 'ডাক্তার'),
  'blood': ('🩸', 'রক্তদাতা'),
  'other': ('📇', 'অন্যান্য'),
};

List<int> _ids(String? s) => (s ?? '')
    .split(',')
    .map((e) => int.tryParse(e.trim()))
    .whereType<int>()
    .toList();

DateTime? _d(String? s) => (s == null || s.isEmpty) ? null : Reminder.parseYmd(s);
String? _s(DateTime? d) => d == null ? null : Reminder.ymd(d);

bool _leap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// [d]-র মাস/দিন অনুযায়ী আজ বা তার পরের প্রথম তারিখ (প্রতি বছরের জন্য)।
DateTime nextOccurrence(DateTime d, {DateTime? from}) {
  final today = dateOnly(from ?? DateTime.now());
  DateTime cand(int y) =>
      DateTime(y, d.month, (d.month == 2 && d.day == 29 && !_leap(y)) ? 28 : d.day);
  var c = cand(today.year);
  if (c.isBefore(today)) c = cand(today.year + 1);
  return c;
}

int daysUntil(DateTime date) => dateOnly(date).difference(dateOnly(DateTime.now())).inDays;

class FamilyMember {
  int? id;
  String name;
  String relation;
  DateTime? birthDate;
  String blood;
  String phone;
  String note;
  List<int> bdayRem;
  int createdAt;

  FamilyMember({
    this.id,
    required this.name,
    this.relation = 'অন্যান্য',
    this.birthDate,
    this.blood = '',
    this.phone = '',
    this.note = '',
    List<int>? bdayRem,
    int? createdAt,
  })  : bdayRem = bdayRem ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'relation': relation,
        'birth_date': _s(birthDate),
        'blood': blood,
        'phone': phone,
        'note': note,
        'bday_rem': bdayRem.join(','),
        'created_at': createdAt,
      };

  factory FamilyMember.fromMap(Map<String, dynamic> m) => FamilyMember(
        id: m['id'] as int,
        name: m['name'] as String,
        relation: (m['relation'] as String?) ?? 'অন্যান্য',
        birthDate: _d(m['birth_date'] as String?),
        blood: (m['blood'] as String?) ?? '',
        phone: (m['phone'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        bdayRem: _ids(m['bday_rem'] as String?),
        createdAt: m['created_at'] as int?,
      );

  /// "৩২ বছর" / "৫ মাস" / "১২ দিন"
  String? get ageLabel {
    if (birthDate == null) return null;
    final now = DateTime.now();
    final b = birthDate!;
    var years = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) years--;
    if (years >= 1) return '${bn(years)} বছর';
    var months = (now.year - b.year) * 12 + now.month - b.month;
    if (now.day < b.day) months--;
    if (months >= 1) return '${bn(months)} মাস';
    final days = dateOnly(now).difference(dateOnly(b)).inDays;
    return '${bn(days < 0 ? 0 : days)} দিন';
  }

  /// পরবর্তী জন্মদিনে কত বছর পূর্ণ হবে।
  int? get turningAge =>
      birthDate == null ? null : nextOccurrence(birthDate!).year - birthDate!.year;
}

class FamilyDate {
  int? id;
  String title;
  String kind; // 'anniversary' | 'other'
  DateTime date; // মূল তারিখ (যেমন বিয়ের দিন)
  String note;
  List<int> rem;
  int createdAt;

  FamilyDate({
    this.id,
    required this.title,
    this.kind = 'other',
    required this.date,
    this.note = '',
    List<int>? rem,
    int? createdAt,
  })  : rem = rem ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  String get emoji => kind == 'anniversary' ? '💍' : '📌';

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'kind': kind,
        'date': Reminder.ymd(date),
        'note': note,
        'rem': rem.join(','),
        'created_at': createdAt,
      };

  factory FamilyDate.fromMap(Map<String, dynamic> m) => FamilyDate(
        id: m['id'] as int,
        title: m['title'] as String,
        kind: (m['kind'] as String?) ?? 'other',
        date: Reminder.parseYmd(m['date'] as String),
        note: (m['note'] as String?) ?? '',
        rem: _ids(m['rem'] as String?),
        createdAt: m['created_at'] as int?,
      );
}

class FamilyBill {
  int? id;
  String title;
  String type;
  int amount;
  int dueDay; // ১..২৮ — সব মাসে মেলে
  String lastPaidMonth; // 'yyyy-MM' বা ফাঁকা
  String note;
  List<int> rem;
  int createdAt;

  FamilyBill({
    this.id,
    required this.title,
    this.type = 'other',
    this.amount = 0,
    this.dueDay = 10,
    this.lastPaidMonth = '',
    this.note = '',
    List<int>? rem,
    int? createdAt,
  })  : rem = rem ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  String get emoji => (billTypes[type] ?? billTypes['other']!).$1;

  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  bool get paidThisMonth => lastPaidMonth == monthKey(DateTime.now());

  DateTime get dueDateThisMonth {
    final n = DateTime.now();
    return DateTime(n.year, n.month, dueDay);
  }

  /// আজ থেকে এই মাসের ডিউ ডেট পর্যন্ত দিন (ঋণাত্মক = পার হয়ে গেছে)।
  int get daysToDue => daysUntil(dueDateThisMonth);

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'type': type,
        'amount': amount,
        'due_day': dueDay,
        'last_paid_month': lastPaidMonth,
        'note': note,
        'rem': rem.join(','),
        'created_at': createdAt,
      };

  factory FamilyBill.fromMap(Map<String, dynamic> m) => FamilyBill(
        id: m['id'] as int,
        title: m['title'] as String,
        type: (m['type'] as String?) ?? 'other',
        amount: (m['amount'] as int?) ?? 0,
        dueDay: ((m['due_day'] as num?)?.toInt() ?? 10).clamp(1, 28),
        lastPaidMonth: (m['last_paid_month'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        rem: _ids(m['rem'] as String?),
        createdAt: m['created_at'] as int?,
      );
}

class FamilyContact {
  int? id;
  String name;
  String kind;
  String phone;
  String note;
  int createdAt;

  FamilyContact({
    this.id,
    required this.name,
    this.kind = 'emergency',
    this.phone = '',
    this.note = '',
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  String get emoji => (contactKinds[kind] ?? contactKinds['other']!).$1;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind,
        'phone': phone,
        'note': note,
        'created_at': createdAt,
      };

  factory FamilyContact.fromMap(Map<String, dynamic> m) => FamilyContact(
        id: m['id'] as int,
        name: m['name'] as String,
        kind: (m['kind'] as String?) ?? 'emergency',
        phone: (m['phone'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        createdAt: m['created_at'] as int?,
      );
}
