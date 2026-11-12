/// A single জমা (income) or খরচ (expense) transaction. `date` is stored
/// as 'YYYY-MM-DD' (not a millis timestamp like the rest of the app) so
/// month-grouping and "does today have an entry" checks are simple
/// string operations — the exact time of day never matters here.
class CashbookEntry {
  final int? id;
  final int accountId;
  final String type; // 'in' | 'out'
  final double amount;
  final String category; // category id — see CashbookService.categories
  final String note;
  final String date; // 'YYYY-MM-DD'
  final String? voucherImage; // base64-encoded photo of the receipt, optional
  final bool recurring;
  final int createdAt;
  final int updatedAt;

  CashbookEntry({
    this.id,
    required this.accountId,
    required this.type,
    required this.amount,
    required this.category,
    required this.note,
    required this.date,
    this.voucherImage,
    this.recurring = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CashbookEntry.fromMap(Map<String, dynamic> m) => CashbookEntry(
        id: m['id'] as int?,
        accountId: m['account_id'] as int,
        type: m['type'] as String,
        amount: (m['amount'] as num).toDouble(),
        category: m['category'] as String,
        note: m['note'] as String? ?? '',
        date: m['date'] as String,
        voucherImage: m['voucher_image'] as String?,
        recurring: (m['recurring'] as int? ?? 0) == 1,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'account_id': accountId,
        'type': type,
        'amount': amount,
        'category': category,
        'note': note,
        'date': date,
        'voucher_image': voucherImage,
        'recurring': recurring ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  CashbookEntry copyWith({
    int? accountId,
    String? type,
    double? amount,
    String? category,
    String? note,
    String? date,
    String? voucherImage,
    bool? recurring,
    int? createdAt,
    int? updatedAt,
    bool clearId = false, // recurring কপিতে পুরনো id রাখলে UNIQUE constraint ক্র্যাশ হয়
  }) =>
      CashbookEntry(
        id: clearId ? null : id,
        accountId: accountId ?? this.accountId,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        note: note ?? this.note,
        date: date ?? this.date,
        voucherImage: voucherImage ?? this.voucherImage,
        recurring: recurring ?? this.recurring,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  String get monthKey => date.substring(0, 7); // 'YYYY-MM'
}
