import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/cashbook_account.dart';
import '../models/cashbook_entry.dart';
import '../models/cashbook_budget.dart';
import '../models/cashbook_essential.dart';
import '../models/cashbook_debt.dart';
import '../services/cashbook_widget_service.dart';
import '../services/spending_guard.dart';
import '../../services/settings_service.dart';

/// The Cashbook is deliberately kept out of mymanager.db — its own file
/// (cashbook.db), its own version history, its own migrations. Nothing
/// about the rest of the app (projects/ideas/vault) ever has to know
/// this table layout exists, and vice versa.
class CashbookDB {
  static Database? _db;
  static const _version = 2;
  static const fileName = 'cashbook.db';

  static Future<Database> get db async {
    _db ??= await _initDB();
    return _db!;
  }

  static Future<Database> _initDB() async {
    final path = join(await getDatabasesPath(), fileName);
    return openDatabase(path, version: _version, onCreate: _onCreate, onUpgrade: _onUpgrade);
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // v2: আবশ্যিক খরচ (আগের "বাজেট" ট্যাবের জায়গায়)। পুরনো টেবিল/ডেটা যেমন ছিল তেমনই থাকে।
    if (oldV < 2) await _createEssentials(db);
  }

  static Future<void> _createEssentials(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS essentials(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        amount REAL NOT NULL,
        due_day INTEGER DEFAULT 0,
        category TEXT NOT NULL DEFAULT 'bill',
        monthly INTEGER DEFAULT 1,
        paid_month TEXT,
        entry_id INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE accounts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        icon TEXT NOT NULL DEFAULT '👛',
        sort_order INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE entries(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        note TEXT,
        date TEXT NOT NULL,
        voucher_image TEXT,
        recurring INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(account_id) REFERENCES accounts(id)
      )
    ''');
    await db.execute('''
      CREATE TABLE budgets(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL UNIQUE,
        monthly_limit REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE debts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT,
        cleared INTEGER DEFAULT 0,
        date TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await _createEssentials(db);
    // First-run only: seed a starting "নগদ" wallet so the account
    // switcher isn't empty on day one.
    await db.insert('accounts', {
      'name': 'নগদ',
      'icon': '💵',
      'sort_order': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── ACCOUNTS ──────────────────────────────────────────
  static Future<List<CashbookAccount>> getAccounts() async {
    final d = await db;
    final rows = await d.query('accounts', orderBy: 'id DESC');
    return rows.map(CashbookAccount.fromMap).toList();
  }

  static Future<int> insertAccount(CashbookAccount a) async {
    final d = await db;
    return d.insert('accounts', a.toMap());
  }

  static Future<void> deleteAccount(int id) async {
    final d = await db;
    await d.delete('entries', where: 'account_id=?', whereArgs: [id]);
    await d.delete('accounts', where: 'id=?', whereArgs: [id]);
  }

  static Future<void> renameAccount(int id, String newName) async {
    final d = await db;
    await d.update('accounts', {'name': newName}, where: 'id=?', whereArgs: [id]);
  }

  /// Balance of every account at once, for the "সব হিসাব" overview —
  /// one query per account is fine at this scale (dozens, not thousands).
  static Future<Map<int, double>> getAllBalances() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT account_id,
        COALESCE(SUM(CASE WHEN type='in' THEN amount ELSE -amount END), 0) as balance
      FROM entries GROUP BY account_id
    ''');
    return {for (final r in rows) r['account_id'] as int: (r['balance'] as num).toDouble()};
  }

  // Matches the exact spelling used by the legacy app's own month-named
  // ledgers (imported ones say "ফেব্রুয়ারী"/"আগষ্ট", not the more common
  // "ফেব্রুয়ারি"/"আগস্ট") — so a freshly auto-created month never ends up
  // as a separate, differently-spelled duplicate of an old one.
  static const _ledgerMonthNames = ['জানুয়ারি', 'ফেব্রুয়ারী', 'মার্চ', 'এপ্রিল', 'মে', 'জুন',
    'জুলাই', 'আগষ্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর'];
  static const _bnDigit = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
  static String _toBnDigits(int n) => n.toString().split('').map((c) => _bnDigit[int.parse(c)]).join();

  /// Creates this calendar month's ledger (e.g. "সেপ্টেম্বর-২০২৬") the
  /// first time the Cashbook is opened after the month has turned over —
  /// called from screen load, same "recompute on open" pattern as
  /// recurring entries and the reminder notification. Never touches or
  /// renames past months; only ever adds the current one, once.
  static Future<void> ensureCurrentMonthLedger() async {
    final now = DateTime.now();
    final name = '${_ledgerMonthNames[now.month - 1]}-${_toBnDigits(now.year)}';
    final d = await db;
    final existing = await d.query('accounts', where: 'name=?', whereArgs: [name], limit: 1);
    if (existing.isEmpty) {
      await d.insert('accounts', {
        'name': name,
        'icon': '📒',
        'sort_order': 0,
        'created_at': now.millisecondsSinceEpoch,
      });
    }
  }

  /// চলতি মাসের খাতা (না থাকলে বানায়) — হোম উইজেট ও দ্রুত-এন্ট্রি এটাই ব্যবহার করে।
  static Future<CashbookAccount> currentMonthAccount() async {
    await ensureCurrentMonthLedger();
    final now = DateTime.now();
    final name = '${_ledgerMonthNames[now.month - 1]}-${_toBnDigits(now.year)}';
    final d = await db;
    final rows = await d.query('accounts', where: 'name=?', whereArgs: [name], limit: 1);
    return CashbookAccount.fromMap(rows.first);
  }

  // ── ENTRIES ───────────────────────────────────────────
  static Future<List<CashbookEntry>> getEntries({int? accountId}) async {
    final d = await db;
    final rows = accountId == null
        ? await d.query('entries', orderBy: 'date DESC, id DESC')
        : await d.query('entries',
            where: 'account_id=?', whereArgs: [accountId], orderBy: 'date DESC, id DESC');
    return rows.map(CashbookEntry.fromMap).toList();
  }

  /// All entries whose note/category/amount text contains [query] — the
  /// global search that reaches across every account at once.
  static Future<List<CashbookEntry>> searchEntries(String query) async {
    final d = await db;
    final q = '%${query.toLowerCase()}%';
    final rows = await d.query('entries',
        where: 'LOWER(note) LIKE ? OR LOWER(category) LIKE ? OR CAST(amount AS TEXT) LIKE ?',
        whereArgs: [q, q, q], orderBy: 'date DESC, id DESC');
    return rows.map(CashbookEntry.fromMap).toList();
  }

  static Future<int> insertEntry(CashbookEntry e) async {
    final d = await db;
    final id = await d.insert('entries', e.toMap());
    CashbookWidgetService.refresh();
    SpendingGuard.changes.value++; // হোম উইজেট হালনাগাদ (best-effort)
    return id;
  }

  static Future<void> updateEntry(CashbookEntry e) async {
    final d = await db;
    await d.update('entries', e.toMap(), where: 'id=?', whereArgs: [e.id]);
    CashbookWidgetService.refresh();
    SpendingGuard.changes.value++;
  }

  static Future<void> deleteEntry(int id) async {
    final d = await db;
    await d.delete('entries', where: 'id=?', whereArgs: [id]);
    CashbookWidgetService.refresh();
    SpendingGuard.changes.value++;
  }

  static String todayIso() => DateTime.now().toIso8601String().substring(0, 10);

  /// Used by the 8pm reminder — if today already has at least one entry
  /// (in any account) there's nothing to nudge the user about.
  static Future<bool> hasEntryToday() async {
    final d = await db;
    final rows = await d.query('entries', where: 'date=?', whereArgs: [todayIso()], limit: 1);
    return rows.isNotEmpty;
  }

  /// For every entry marked 🔁 recurring whose month is in the past,
  /// create this month's copy if one doesn't already exist — called once
  /// when the Cashbook screen opens so bills/salary keep showing up
  /// without the user re-typing them every month.
  static Future<int> processRecurring() async {
    final all = await getEntries();
    final thisMonth = todayIso().substring(0, 7);
    final recurringSources = all.where((e) => e.recurring && e.monthKey != thisMonth);
    final latestBySignature = <String, CashbookEntry>{};
    for (final e in recurringSources) {
      final sig = '${e.accountId}|${e.category}|${e.note}|${e.type}';
      final prev = latestBySignature[sig];
      if (prev == null || e.date.compareTo(prev.date) > 0) latestBySignature[sig] = e;
    }
    int created = 0;
    for (final src in latestBySignature.values) {
      final sig = '${src.accountId}|${src.category}|${src.note}|${src.type}';
      final alreadyThisMonth = all.any((e) =>
          e.monthKey == thisMonth &&
          '${e.accountId}|${e.category}|${e.note}|${e.type}' == sig);
      if (!alreadyThisMonth) {
        final n = DateTime.now().millisecondsSinceEpoch;
        try {
          await insertEntry(src.copyWith(
              date: todayIso(), createdAt: n, updatedAt: n, clearId: true));
          created++;
        } catch (_) {
          // একটা recurring ব্যর্থ হলেও খাতা খোলা আটকাবে না
        }
      }
    }
    return created;
  }

  // ── আবশ্যিক খরচ ───────────────────────────────────────
  static String _thisMonth() => todayIso().substring(0, 7);

  static Future<List<CashbookEssential>> getEssentials() async {
    final d = await db;
    final rows = await d.query('essentials', orderBy: 'id ASC');
    return rows.map(CashbookEssential.fromMap).toList();
  }

  static Future<void> upsertEssential(CashbookEssential e) async {
    final d = await db;
    if (e.id == null) {
      await d.insert('essentials', e.toMap());
    } else {
      // শুধু সম্পাদনযোগ্য ঘর বদলায়; "মেটানো হয়েছে" অবস্থা অক্ষত থাকে।
      await d.update(
        'essentials',
        {
          'title': e.title,
          'amount': e.amount,
          'due_day': e.dueDay,
          'category': e.category,
          'monthly': e.monthly ? 1 : 0,
        },
        where: 'id=?',
        whereArgs: [e.id],
      );
    }
    SpendingGuard.changes.value++;
  }

  /// মুছলে আগে মেটানো এন্ট্রি খাতায় থেকে যায় (টাকা সত্যিই খরচ হয়েছিল) — শুধু তালিকা থেকে যায়।
  static Future<void> deleteEssential(int id) async {
    final d = await db;
    await d.delete('essentials', where: 'id=?', whereArgs: [id]);
    SpendingGuard.changes.value++;
  }

  /// "ঠিক আছে" চাপলে ([paid] = true): চলতি মাসের খাতায় নিজে খরচ-এন্ট্রি লেখা হয় — ক্যাশ কমে।
  /// টিক তুলে নিলে ([paid] = false): ওই এন্ট্রি মুছে যায়। একই মাসে কখনও দুবার খরচ লেখা হয় না।
  static Future<void> setEssentialPaid(int id, bool paid) async {
    final d = await db;
    final rows = await d.query('essentials', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final e = CashbookEssential.fromMap(rows.first);
    final mk = _thisMonth();

    if (paid) {
      if (e.paidIn(mk)) return;
      final acc = await currentMonthAccount();
      final ms = DateTime.now().millisecondsSinceEpoch;
      // এন্ট্রি + টিক একই ট্রানজ্যাকশনে — মাঝপথে ব্যর্থ হলে কোনোটাই
      // লেখা হয় না (আগে এন্ট্রি লেখা হয়ে টিক বসত না; আবার চাপলে
      // দ্বিতীয় খরচ-এন্ট্রি হয়ে যেত)।
      await d.transaction((txn) async {
        final entryId = await txn.insert('entries', CashbookEntry(
          accountId: acc.id!,
          type: 'out',
          amount: e.amount,
          category: e.category,
          note: 'আবশ্যিক খরচ: ${e.title}',
          date: todayIso(),
          createdAt: ms,
          updatedAt: ms,
        ).toMap());
        await txn.update('essentials', {'paid_month': mk, 'entry_id': entryId}, where: 'id=?', whereArgs: [id]);
      });
      CashbookWidgetService.refresh();
    } else {
      if (!e.paidIn(mk)) return;
      await d.transaction((txn) async {
        if (e.entryId != null) {
          await txn.delete('entries', where: 'id=?', whereArgs: [e.entryId]);
        }
        await txn.update('essentials', {'paid_month': null, 'entry_id': null}, where: 'id=?', whereArgs: [id]);
      });
      CashbookWidgetService.refresh();
    }
    SpendingGuard.changes.value++;
  }

  // ── BUDGETS (পুরনো — এখন আর দেখানো হয় না; ব্যাকআপের সামঞ্জস্যের জন্য রাখা) ──
  static Future<List<CashbookBudget>> getBudgets() async {
    final d = await db;
    final rows = await d.query('budgets', orderBy: 'id ASC');
    return rows.map(CashbookBudget.fromMap).toList();
  }

  static Future<void> upsertBudget(CashbookBudget b) async {
    final d = await db;
    final existing = await d.query('budgets', where: 'category=?', whereArgs: [b.category]);
    if (existing.isEmpty) {
      await d.insert('budgets', b.toMap());
    } else {
      await d.update('budgets', {'monthly_limit': b.monthlyLimit},
          where: 'category=?', whereArgs: [b.category]);
    }
    SpendingGuard.changes.value++;
  }

  static Future<void> deleteBudget(int id) async {
    final d = await db;
    await d.delete('budgets', where: 'id=?', whereArgs: [id]);
    SpendingGuard.changes.value++;
  }

  /// Sum of খরচ entries in [category] for the current calendar month,
  /// across every account — a budget is a household-wide limit.
  static Future<double> spentThisMonth(String category) async {
    final d = await db;
    final thisMonth = todayIso().substring(0, 7);
    final rows = await d.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) as total FROM entries
      WHERE type='out' AND category=? AND date LIKE ?
    ''', [category, '$thisMonth%']);
    return (rows.first['total'] as num).toDouble();
  }

  // ── DEBTS (দেনা-পাওনা) ────────────────────────────────
  static Future<List<CashbookDebt>> getDebts() async {
    final d = await db;
    final rows = await d.query('debts', orderBy: 'cleared ASC, date DESC');
    return rows.map(CashbookDebt.fromMap).toList();
  }

  static Future<int> insertDebt(CashbookDebt debt) async {
    final d = await db;
    return d.insert('debts', debt.toMap());
  }

  static const _settleKey = 'debt_settle_entries'; // {"দেনা-id": এন্ট্রি-id}

  static Map<String, dynamic> _settleMap() {
    try {
      return Map<String, dynamic>.from(jsonDecode(SettingsService.getString(_settleKey)) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveSettleMap(Map<String, dynamic> m) =>
      SettingsService.setString(_settleKey, jsonEncode(m));

  /// দেনা/পাওনা মেটানো হলে খাতায় নিজে এন্ট্রি:
  ///  • পাওনা আদায় (lend)   → জমা
  ///  • দেনা পরিশোধ (borrow) → খরচ
  /// টিক তুলে নিলে ওই এন্ট্রিও মুছে যায়; আবার টিক দিলে নতুন করে (কখনো দুবার নয়)।
  /// টিক + খাতার এন্ট্রি একই DB ট্রানজ্যাকশনে — মাঝপথে ব্যর্থ হলে
  /// কোনোটাই বসে না (আগে টিক আগে বসত, এন্ট্রির ত্রুটি চাপা পড়ত —
  /// "টিক আছে, টাকা নেই" অবস্থা হতো)। settle-ম্যাপ SharedPreferences-এ
  /// থাকে বলে সেটা DB কমিটের পরেই বদলায়। ফেরত: সফল হলে true।
  static Future<bool> setDebtCleared(int id, bool cleared) async {
    final d = await db;
    final map = _settleMap();
    final key = '$id';
    // ট্রানজ্যাকশনের ভেতরে আলাদা db.query ডাকা যায় না (sqflite আটকে
    // যায়) — যা লাগবে আগেই জোগাড় করো।
    CashbookEntry? newEntry;
    if (cleared && !map.containsKey(key)) {
      final rows = await d.query('debts', where: 'id=?', whereArgs: [id]);
      if (rows.isNotEmpty) {
        final debt = CashbookDebt.fromMap(rows.first);
        final acc = await currentMonthAccount();
        final ms = DateTime.now().millisecondsSinceEpoch;
        final isLend = debt.type == 'lend';
        newEntry = CashbookEntry(
          accountId: acc.id!,
          type: isLend ? 'in' : 'out',
          amount: debt.amount,
          category: 'other',
          note: isLend ? 'পাওনা আদায়: ${debt.name}' : 'দেনা পরিশোধ: ${debt.name}',
          date: todayIso(),
          createdAt: ms,
          updatedAt: ms,
        );
      }
    }
    final removeEntryId = !cleared ? (map[key] as num?)?.toInt() : null;
    int? insertedId;
    try {
      await d.transaction((txn) async {
        await txn.update('debts', {'cleared': cleared ? 1 : 0}, where: 'id=?', whereArgs: [id]);
        if (newEntry != null) {
          insertedId = await txn.insert('entries', newEntry.toMap());
        }
        if (removeEntryId != null) {
          await txn.delete('entries', where: 'id=?', whereArgs: [removeEntryId]);
        }
      });
    } catch (_) {
      return false;
    }
    if (insertedId != null) {
      map[key] = insertedId;
      await _saveSettleMap(map);
      CashbookWidgetService.refresh();
      SpendingGuard.changes.value++;
    } else if (removeEntryId != null) {
      map.remove(key);
      await _saveSettleMap(map);
      CashbookWidgetService.refresh();
      SpendingGuard.changes.value++;
    }
    return true;
  }

  static Future<void> deleteDebt(int id) async {
    final d = await db;
    await d.delete('debts', where: 'id=?', whereArgs: [id]);
    // খাতার আগের এন্ট্রি থেকে যাবে (টাকা সত্যিই লেনদেন হয়েছিল) — শুধু যোগসূত্র মোছা।
    final m = _settleMap();
    if (m.remove('$id') != null) await _saveSettleMap(m);
  }

  /// [type] ('in'/'out') এন্ট্রিতে ব্যবহৃত ক্যাটাগরি, সবচেয়ে সাম্প্রতিক আগে।
  static Future<List<String>> recentCategoryIds(String type) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT category, MAX(created_at) AS t FROM entries WHERE type=? AND category IS NOT NULL GROUP BY category ORDER BY t DESC',
        [type]);
    return rows.map((r) => r['category'] as String).toList();
  }

  // ── FULL EXPORT/IMPORT (for Drive backup) ────────────
  static Future<Map<String, dynamic>> exportAll() async {
    final d = await db;
    return {
      'accounts': await d.query('accounts'),
      'entries': await d.query('entries'),
      'budgets': await d.query('budgets'),
      'debts': await d.query('debts'),
      'essentials': await d.query('essentials'),
    };
  }

  static Future<void> importAll(Map<String, dynamic> data) async {
    final d = await db;
    await d.transaction((txn) async {
      // চাবি থাকলেই শুধু সেই টেবিল বদলাও — ব্যাকআপে কোনো টেবিলের চাবি
      // না থাকলে (পুরনো/আংশিক ফাইল) বর্তমান ডেটা মুছবে না। আগে
      // essentials ছাড়া বাকি টেবিল নিঃশর্তে মোছা হতো বলে চাবি-হারা
      // ব্যাকআপে দেনা/বাজেট চিরতরে যেত।
      Future<void> swap(String table) async {
        if (!data.containsKey(table)) return;
        await txn.delete(table);
        for (final row in (data[table] as List? ?? [])) {
          await txn.insert(table, Map<String, dynamic>.from(row));
        }
      }
      await swap('accounts');
      await swap('entries');
      await swap('budgets');
      await swap('debts');
      await swap('essentials');
    });
  }

  // ── LEGACY IMPORT (e.g. from another cash-book app's .db export) ────
  /// Accounts are matched or created by name, so importing the same
  /// backup twice never creates duplicate wallets — only new entries
  /// would be appended (harmless duplicates in the entries list, but at
  /// least accounts stay clean). [entries] items need: accountName,
  /// type ('in'/'out'), amount, date ('YYYY-MM-DD'), note.
  static Future<int> importLegacy({
    required List<String> accountNames,
    required List<Map<String, dynamic>> entries,
  }) async {
    final d = await db;
    int inserted = 0;
    await d.transaction((txn) async {
      final nameToId = <String, int>{};
      final existing = await txn.query('accounts');
      for (final row in existing) {
        nameToId[row['name'] as String] = row['id'] as int;
      }
      for (final name in accountNames) {
        if (!nameToId.containsKey(name)) {
          final id = await txn.insert('accounts', {
            'name': name,
            'icon': '📒',
            'sort_order': nameToId.length,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          });
          nameToId[name] = id;
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final e in entries) {
        final accId = nameToId[e['accountName']];
        if (accId == null) continue;
        await txn.insert('entries', {
          'account_id': accId,
          'type': e['type'],
          'amount': e['amount'],
          'category': 'other',
          'note': e['note'] ?? '',
          'date': e['date'],
          'voucher_image': null,
          'recurring': 0,
          'created_at': now,
          'updated_at': now,
        });
        inserted++;
      }
    });
    return inserted;
  }
}
