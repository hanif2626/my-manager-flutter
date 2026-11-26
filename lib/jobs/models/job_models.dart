import '../../reminder/models/reminder.dart';

/// সার্কুলারের অবস্থা — ক্রম অনুযায়ী এগোয়।
const circularStatuses = <String, String>{
  'watching': 'সেভ করা (আবেদন বাকি)',
  'applied': 'আবেদন করেছি',
  'admit': 'প্রবেশপত্র পেয়েছি',
  'exam_done': 'পরীক্ষা দিয়েছি',
  'result': 'ফলাফল এসেছে',
  'closed': 'বাদ / বন্ধ',
};

const circularStatusIcons = <String, String>{
  'watching': '👀',
  'applied': '📨',
  'admit': '🎫',
  'exam_done': '✍️',
  'result': '🏁',
  'closed': '🚫',
};

List<int> _ids(String? s) => (s ?? '')
    .split(',')
    .map((e) => int.tryParse(e.trim()))
    .whereType<int>()
    .toList();

DateTime? _d(String? s) => (s == null || s.isEmpty) ? null : Reminder.parseYmd(s);
String? _s(DateTime? d) => d == null ? null : Reminder.ymd(d);

class Circular {
  int? id;
  String title;
  String org;
  String post;
  DateTime? deadline; // আবেদনের শেষ তারিখ
  DateTime? examDate;
  int fee;
  String status;
  String url;
  String note;
  List<int> deadlineRem; // এই সার্কুলারের জন্য তৈরি রিমাইন্ডার id
  List<int> examRem;
  int createdAt;

  Circular({
    this.id,
    required this.title,
    this.org = '',
    this.post = '',
    this.deadline,
    this.examDate,
    this.fee = 0,
    this.status = 'watching',
    this.url = '',
    this.note = '',
    List<int>? deadlineRem,
    List<int>? examRem,
    int? createdAt,
  })  : deadlineRem = deadlineRem ?? [],
        examRem = examRem ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'org': org,
        'post': post,
        'deadline': _s(deadline),
        'exam_date': _s(examDate),
        'fee': fee,
        'status': status,
        'url': url,
        'note': note,
        'deadline_rem': deadlineRem.join(','),
        'exam_rem': examRem.join(','),
        'created_at': createdAt,
      };

  factory Circular.fromMap(Map<String, dynamic> m) => Circular(
        id: (m['id'] as num?)?.toInt(),
        title: (m['title'] ?? '').toString(),
        org: (m['org'] ?? '').toString(),
        post: (m['post'] ?? '').toString(),
        deadline: _d(m['deadline']?.toString()),
        examDate: _d(m['exam_date']?.toString()),
        fee: (m['fee'] as num?)?.toInt() ?? 0,
        status: circularStatuses.containsKey(m['status'])
            ? m['status'] as String
            : 'watching',
        url: (m['url'] ?? '').toString(),
        note: (m['note'] ?? '').toString(),
        deadlineRem: _ids(m['deadline_rem']?.toString()),
        examRem: _ids(m['exam_rem']?.toString()),
        createdAt: (m['created_at'] as num?)?.toInt(),
      );

  int? get daysLeft => deadline == null
      ? null
      : dateOnly(deadline!).difference(dateOnly(DateTime.now())).inDays;

  int? get examDaysLeft => examDate == null
      ? null
      : dateOnly(examDate!).difference(dateOnly(DateTime.now())).inDays;

  /// আবেদনের সময় এখনো বাকি ও আবেদন করা হয়নি।
  bool get needsAction =>
      status == 'watching' && daysLeft != null && daysLeft! >= 0;
}

class JobDoc {
  int? id;
  String title;
  bool done;
  int sort;
  JobDoc({this.id, required this.title, this.done = false, this.sort = 0});

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'done': done ? 1 : 0,
        'sort': sort,
      };

  factory JobDoc.fromMap(Map<String, dynamic> m) => JobDoc(
        id: m['id'] as int,
        title: m['title'] as String,
        done: (m['done'] as int? ?? 0) == 1,
        sort: (m['sort'] as int?) ?? 0,
      );
}
