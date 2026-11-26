/// একটা রিমাইন্ডার — হেডিং + নোট + এক বা একাধিক সময় + (ঐচ্ছিক) রিপিট।
///
/// * [repeat]: none | daily | weekly | monthly | yearly
/// * [done]: এক-বারের রিমাইন্ডার শেষ হলে (বা রিপিট সিরিজ বন্ধ করলে) true
/// * [lastDoneDate]: রিপিট রিমাইন্ডারে "কোন তারিখেরটা শেষ" — সেই দিনের
///   নোটিফিকেশন আর আসে না, পরের দিন থেকে আবার আসে।
const _bnDigits = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

String bn(Object v) => v
    .toString()
    .replaceAllMapped(RegExp(r'\d'), (m) => _bnDigits[int.parse(m[0]!)]);

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

const _bnMonths = [
  'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন',
  'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর',
];

const _bnWeekdays = ['সোম', 'মঙ্গল', 'বুধ', 'বৃহস্পতি', 'শুক্র', 'শনি', 'রবি'];

class ReminderKind {
  final String key;
  final String emoji;
  final String label;
  const ReminderKind(this.key, this.emoji, this.label);
}

const reminderKinds = [
  ReminderKind('note', '📝', 'নোট'),
  ReminderKind('post', '📣', 'পোস্ট/ক্যাপশন'),
  ReminderKind('call', '📞', 'কল করা'),
  ReminderKind('give', '🎁', 'কিছু দেওয়া'),
  ReminderKind('plan', '📅', 'ভবিষ্যৎ প্ল্যান'),
];

ReminderKind kindOf(String key) =>
    reminderKinds.firstWhere((k) => k.key == key, orElse: () => reminderKinds.first);

const reminderRepeats = {
  'none': 'একবার',
  'daily': 'প্রতিদিন',
  'weekly': 'প্রতি সপ্তাহে',
  'monthly': 'প্রতি মাসে',
  'yearly': 'প্রতি বছর',
};

(int, int) parseHm(String s) {
  final p = s.split(':');
  final h = p.isNotEmpty ? (int.tryParse(p[0].trim()) ?? 8) : 8;
  final m = p.length > 1 ? (int.tryParse(p[1].trim()) ?? 0) : 0;
  return (h.clamp(0, 23), m.clamp(0, 59));
}

int _lastDayOfMonth(int year, int month) => DateTime(year, month + 1, 0).day;

int _clampDay(int year, int month, int day) =>
    day.clamp(1, _lastDayOfMonth(year, month));

String hmString(int h, int m) =>
    '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// "08:00" → "সকাল ৮:০০"
String formatTimeBn(String hm) {
  final (h, m) = parseHm(hm);
  final String period;
  if (h >= 4 && h < 12) {
    period = 'সকাল';
  } else if (h >= 12 && h < 16) {
    period = 'দুপুর';
  } else if (h >= 16 && h < 18) {
    period = 'বিকাল';
  } else if (h >= 18 && h < 20) {
    period = 'সন্ধ্যা';
  } else {
    period = 'রাত';
  }
  var h12 = h % 12;
  if (h12 == 0) h12 = 12;
  return '$period ${bn(h12)}:${bn(m.toString().padLeft(2, '0'))}';
}

String formatDateBn(DateTime d, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final diff = dateOnly(d).difference(today).inDays;
  if (diff == 0) return 'আজ';
  if (diff == 1) return 'আগামীকাল';
  if (diff == -1) return 'গতকাল';
  final y = d.year == today.year ? '' : ' ${bn(d.year)}';
  return '${bn(d.day)} ${_bnMonths[d.month - 1]}$y';
}

String weekdayBn(DateTime d) => _bnWeekdays[d.weekday - 1];

class Reminder {
  int? id;
  String title;
  String note;
  String kind;
  DateTime date; // শুরুর/নির্দিষ্ট তারিখ (শুধু তারিখ অংশ)
  List<String> times; // "HH:mm", sorted
  String repeat;
  bool done;
  String? lastDoneDate; // yyyy-MM-dd
  int createdAt;

  Reminder({
    this.id,
    required this.title,
    this.note = '',
    this.kind = 'note',
    required this.date,
    required this.times,
    this.repeat = 'none',
    this.done = false,
    this.lastDoneDate,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime parseYmd(String s) {
    final p = s.split('-');
    final y = p.isNotEmpty ? (int.tryParse(p[0].trim()) ?? 2000) : 2000;
    final m = (p.length > 1 ? (int.tryParse(p[1].trim()) ?? 1) : 1).clamp(1, 12);
    final d = p.length > 2 ? (int.tryParse(p[2].trim()) ?? 1) : 1;
    return DateTime(y, m, _clampDay(y, m, d));
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'note': note,
        'kind': kind,
        'date': ymd(date),
        'times': (List<String>.from(times)..sort()).join(','),
        'repeat': repeat,
        'done': done ? 1 : 0,
        'last_done_date': lastDoneDate,
        'created_at': createdAt,
      };

  factory Reminder.fromMap(Map<String, dynamic> m) => Reminder(
        id: m['id'] as int,
        title: m['title'] as String,
        note: (m['note'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'note',
        date: parseYmd(m['date'] as String),
        times: ((m['times'] as String?) ?? '')
            .split(',')
            .where((e) => e.isNotEmpty)
            .toList()
          ..sort(),
        repeat: (m['repeat'] as String?) ?? 'none',
        done: (m['done'] as int? ?? 0) == 1,
        lastDoneDate: m['last_done_date'] as String?,
        createdAt: m['created_at'] as int?,
      );

  /// এই তারিখে কি রিমাইন্ডারটা ঘটার কথা?
  bool occursOn(DateTime day) {
    final start = dateOnly(date);
    final d = dateOnly(day);
    if (d.isBefore(start)) return false;
    switch (repeat) {
      case 'daily':
        return true;
      case 'weekly':
        return d.weekday == start.weekday;
      case 'monthly':
        // ৩১ তারিখের রিমাইন্ডার ছোট মাসে মাসের শেষ দিনে আসবে — হারাবে না।
        return d.day == _clampDay(d.year, d.month, start.day);
      case 'yearly':
        // ২৯ ফেব্রুয়ারি লিপ-ইয়ার ছাড়া ২৮ ফেব্রুয়ারিতে আসবে।
        return d.month == start.month &&
            d.day == _clampDay(d.year, d.month, start.day);
      default:
        return d == start;
    }
  }

  bool get repeats => repeat != 'none';

  /// আজকের জন্য বাকি আছে (এখনো Done দেওয়া হয়নি)।
  bool isDueToday(DateTime today) =>
      !done && occursOn(today) && lastDoneDate != ymd(today);

  /// এক-বারের রিমাইন্ডার, তারিখ পেরিয়ে গেছে অথচ Done হয়নি।
  bool isOverdue(DateTime today) =>
      !done && !repeats && dateOnly(date).isBefore(today);

  /// আজকের পরের পরবর্তী তারিখ (আসছে ট্যাবের জন্য)।
  DateTime? nextDateAfter(DateTime today) {
    if (done) return null;
    if (!repeats) {
      return dateOnly(date).isAfter(today) ? dateOnly(date) : null;
    }
    for (var i = 1; i <= 400; i++) {
      final d = today.add(Duration(days: i));
      final day = DateTime(d.year, d.month, d.day);
      if (occursOn(day)) return day;
    }
    return null;
  }

  String get repeatLabel {
    switch (repeat) {
      case 'weekly':
        return 'প্রতি ${weekdayBn(date)}বার';
      case 'monthly':
        return 'প্রতি মাসের ${bn(date.day)} তারিখ';
      case 'yearly':
        return 'প্রতি বছর ${bn(date.day)} ${_bnMonths[date.month - 1]}';
      default:
        return reminderRepeats[repeat] ?? '';
    }
  }
}
