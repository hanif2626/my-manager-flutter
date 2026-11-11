import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../reminder/models/reminder.dart' show bn, dateOnly;
import '../../services/settings_service.dart';
import '../db/cashbook_db.dart';
import '../models/cashbook_essential.dart';
import 'cashbook_notification_service.dart';

enum GuardLevel { ok, near, danger }

String _money(double v) {
  final n = v.round().abs();
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i != 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${v < 0 ? '-' : ''}৳${bn(b.toString())}';
}

/// খাতায় এখন কত টাকা আছে আর এ মাসের বাকি আবশ্যিক খরচ কত — তার তুলনা।
class GuardReport {
  final double balance; // চলতি মাসের খাতার ব্যালেন্স (প্রস্তাবিত খরচ বাদ দিয়ে)
  final double reserved; // এ মাসে বাকি আবশ্যিক খরচের মোট
  final List<CashbookEssential> unpaid;
  final double margin; // "কাছাকাছি" ধরার সীমা
  GuardReport(this.balance, this.reserved, this.unpaid, this.margin);

  /// আবশ্যিক খরচ মেটানোর পরে হাতে থাকবে কত — এটাই "নিরাপদ খরচের" সীমা।
  double get free => balance - reserved;

  GuardLevel get level {
    if (reserved <= 0) return GuardLevel.ok;
    if (free < 0) return GuardLevel.danger;
    if (free < margin) return GuardLevel.near;
    return GuardLevel.ok;
  }

  /// জরুরি খরচ-সতর্কতার পুরনো নাম (বাইরের কোড এটাও ব্যবহার করে)।
  GuardLevel get essentialsLevel => level;

  /// এ মাসে কোনো আবশ্যিক খরচ (কিস্তি, হাসু...) এখনও বাকি আছে? থাকলে টাকা যথেষ্ট হলেও
  /// অকারণ খরচে সতর্ক করা হয় — "হিসাব করে ব্যয় করো"।
  bool get hasPending => unpaid.isNotEmpty;

  String get headline {
    if (level == GuardLevel.danger) return '🚨 আবশ্যিক খরচের টাকাই নেই!';
    if (level == GuardLevel.near) return '⚠️ আবশ্যিক খরচের টাকা প্রায় শেষ!';
    if (hasPending) return '📌 কিস্তি/আবশ্যিক খরচ বাকি আছে — হিসাব করে ব্যয় করো';
    return '✅ সব ঠিক আছে';
  }

  /// এক লাইনের সারসংক্ষেপ
  String get essentialsLine => reserved > 0
      ? 'ব্যালেন্স ${_money(balance)} · বাকি আবশ্যিক ${_money(reserved)} → নিরাপদ খরচ ${_money(free)}'
      : 'ব্যালেন্স ${_money(balance)} · এ মাসের কোনো আবশ্যিক খরচ বাকি নেই';

  /// বিস্তারিত লাইন: বাকি আবশ্যিক খরচ (তারিখ অনুযায়ী)
  List<String> get detailLines => pendingLines(unpaid, DateTime.now(), max: 6);

  /// [ref] দিনের হিসাবে "আর কত দিন / কত দিন বকেয়া"সহ প্রতিটা বাকি খরচের লাইন।
  static List<String> pendingLines(List<CashbookEssential> items, DateTime ref, {int max = 6}) {
    final out = <String>[];
    final day = dateOnly(ref);
    final lastDay = DateTime(day.year, day.month + 1, 0).day; // ৩০/৩১ তারিখ ছোট মাসে উপচে না পড়ুক
    for (final e in items.take(max)) {
      var when = '';
      if (e.dueDay > 0) {
        final due = DateTime(day.year, day.month, e.dueDay > lastDay ? lastDay : e.dueDay);
        final d = due.difference(day).inDays;
        when = d < 0 ? ' (${bn(-d)} দিন বকেয়া)' : (d == 0 ? ' (আজই শেষ দিন)' : ' (আর ${bn(d)} দিন)');
      }
      out.add('${e.title} ${_money(e.amount)}$when');
    }
    if (items.length > max) out.add('আরও ${bn(items.length - max)}টা...');
    return out;
  }

  /// নোটিফিকেশনের বডি
  String get notificationBody {
    final lines = <String>[essentialsLine, ...detailLines.take(4).map((e) => '• $e')];
    lines.add('টাকা কম খরচ করুন — আবশ্যিক কাজ আগে করুন।');
    return lines.join('\n');
  }
}

/// "খরচ-প্রহরী": ক্যাশবুকে এখন যত টাকা আছে তা এ মাসের বাকি আবশ্যিক খরচের কাছাকাছি গেলে
/// নোটিফিকেশন বারে স্থায়ী সতর্কতা থাকে (অ্যাপের ভেতরে লাল কার্ড নয় — ব্যবহারকারীর
/// সিদ্ধান্ত, ২০২৬-১১-১১); সঙ্গে খরচ লেখার সময় জানান ও প্রতিদিন ৩ বেলার নোটিফিকেশন।
class SpendingGuard {
  static final ValueNotifier<int> changes = ValueNotifier(0);

  // ── সেটিংস ──
  static bool get enabled => SettingsService.getBool('guard_on', defaultValue: true);
  static int get marginPct => SettingsService.getInt('guard_margin_pct', defaultValue: 30);
  static int get nagMinutes => SettingsService.getInt('guard_nag_min', defaultValue: 120);

  static Future<void> saveSettings({bool? on, int? margin, int? nag}) async {
    if (on != null) await SettingsService.setBool('guard_on', on);
    if (margin != null) await SettingsService.setInt('guard_margin_pct', margin);
    if (nag != null) await SettingsService.setInt('guard_nag_min', nag);
    changes.value++;
  }

  /// আবশ্যিক ক্যাটাগরি — এতে খরচ করলে সতর্কতা দেখানো হয় না (বিল দেওয়াই তো কাজ)।
  static bool isEssentialCategory(String id) => id == 'bill';

  /// [extraSpend]: এখনই যে খরচটা করতে যাচ্ছ তার প্রভাব ধরে হিসাব ("এটা করলে কী হবে")।
  /// [category] আগের সংস্করণের সাথে মিল রাখতে আছে; এখন হিসাবে লাগে না।
  static Future<GuardReport> assess({double extraSpend = 0, String? category}) async {
    final acc = await CashbookDB.currentMonthAccount();
    final entries = await CashbookDB.getEntries(accountId: acc.id);
    var balance = 0.0;
    for (final e in entries) {
      balance += e.type == 'in' ? e.amount : -e.amount;
    }
    balance -= extraSpend;

    // বাকি আবশ্যিক: এ মাসে এখনও মেটানো হয়নি এমন সব।
    final mk = CashbookDB.todayIso().substring(0, 7);
    final unpaid = <CashbookEssential>[];
    var reserved = 0.0;
    try {
      for (final e in await CashbookDB.getEssentials()) {
        if (!e.unpaidIn(mk) || e.amount <= 0) continue;
        unpaid.add(e);
        reserved += e.amount;
      }
    } catch (_) {}
    // তারিখ আগে যেগুলোর; তারিখ ছাড়াগুলো শেষে।
    unpaid.sort((a, b) {
      final x = a.dueDay == 0 ? 99 : a.dueDay;
      final y = b.dueDay == 0 ? 99 : b.dueDay;
      return x.compareTo(y);
    });

    final margin = reserved * marginPct / 100 < 500 ? 500.0 : reserved * marginPct / 100;
    return GuardReport(balance, reserved, unpaid, margin);
  }

  // ───────────── প্রতিদিন ৩ বেলা নোটিফিকেশন ─────────────

  /// ৩ বেলার সময় (দিনের মিনিটে)। ডিফল্ট: সকাল ৯টা, দুপুর ২টা, রাত ৮টা।
  static const _slotKeys = ['guard_slot_1', 'guard_slot_2', 'guard_slot_3'];
  static const _slotDefaults = [9 * 60, 14 * 60, 20 * 60];
  static const slotNames = ['সকাল', 'দুপুর', 'রাত'];

  static int slotMinute(int i) => SettingsService.getInt(_slotKeys[i], defaultValue: _slotDefaults[i]).clamp(0, 1439);

  static Future<void> setSlotMinute(int i, int minute) async {
    await SettingsService.setInt(_slotKeys[i], minute.clamp(0, 1439));
    changes.value++; // বদলালেই নতুন সময়ে আবার বসে যাবে
  }

  static Timer? _rearmTimer;
  static bool _listening = false;

  /// ডাটা (এন্ট্রি / আবশ্যিক খরচ / সেটিংস) বদলালেই নোটিফিকেশন নতুন করে বসানো — যাতে কিস্তি মেটানোর
  /// সাথে সাথে ওই কিস্তির ওয়ার্নিং বন্ধ হয়, আর সব মিটলে ৩ বেলার ওয়ার্নিংই বন্ধ।
  static void _listenForChanges() {
    if (_listening) return;
    _listening = true;
    changes.addListener(() {
      _rearmTimer?.cancel();
      _rearmTimer = Timer(const Duration(seconds: 2), () {
        rearmSlots().catchError((_) {});
        syncOngoing().catchError((_) {});
      });
    });
  }

  static String _tone(int slot) {
    switch (slot) {
      case 0:
        return 'আজ সকাল থেকেই অকারণ খরচ এড়িয়ে চলুন।';
      case 1:
        return 'দুপুরের হিসাব: অন্য কাজে টাকা খরচ করার আগে একবার ভাবুন।';
      default:
        return 'রাতের হিসাব: আজ আর অকারণ খরচ নয় — আগে এগুলো মেটান।';
    }
  }

  /// [items] — [ref] দিনে যেগুলো বাকি; [balance] null হলে (অন্য মাসের স্লট) ব্যালেন্সের লাইন বাদ।
  static ({String title, String body}) _message(
      List<CashbookEssential> items, DateTime ref, int slot, double? balance, bool danger) {
    final total = items.fold<double>(0, (a, e) => a + e.amount);
    final summary = balance == null
        ? 'মোট বাকি ${_money(total)} (${bn(items.length)}টা)'
        : 'মোট বাকি ${_money(total)} (${bn(items.length)}টা) · ক্যাশ ${_money(balance)} → নিরাপদ খরচ ${_money(balance - total)}';
    final lines = <String>[
      summary,
      ...GuardReport.pendingLines(items, ref, max: 8).map((e) => '• $e'),
      'টাকা হিসাব করে ব্যয় করুন — কিস্তি/আবশ্যিক খরচ আগে মেটান। ${_tone(slot)}',
    ];
    final title = danger
        ? '🚨 আবশ্যিক খরচের টাকাই নেই — অন্য খরচ বন্ধ!'
        : '📌 ${bn(items.length)}টা আবশ্যিক খরচ বাকি — হিসাব করে ব্যয় করুন';
    return (title: title, body: lines.join('\n'));
  }

  /// আজকের বাকি ৩ বেলা + আগামীকালের ৩ বেলার সঠিক-সময়ের (exact alarm) নোটিফিকেশন বসায়।
  /// বাকি কোনো আবশ্যিক খরচ না থাকলে বা প্রহরী বন্ধ থাকলে সব বাতিল। idempotent — যতবার খুশি ডাকা যায়।
  static Future<void> rearmSlots() async {
    if (!enabled) {
      await CashbookNotificationService.cancelGuardSlots();
      return;
    }
    final now = DateTime.now();
    final r = await assess();
    if (!r.hasPending) {
      await CashbookNotificationService.cancelGuardSlots();
      return;
    }
    final all = await CashbookDB.getEssentials();
    final todayMk = CashbookDB.todayIso().substring(0, 7);

    final msgs = <({DateTime when, String title, String body, bool danger})>[];
    for (var dayOff = 0; dayOff < 2; dayOff++) {
      final day = DateTime(now.year, now.month, now.day + dayOff);
      final mk = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}';
      final sameMonth = mk == todayMk;
      // অন্য মাসে গেলে: প্রতিমাসের সবগুলোই আবার বাকি — তখনকার ব্যালেন্স জানা নেই, তাই ব্যালেন্সের লাইন নেই।
      final items = sameMonth ? r.unpaid : (all.where((e) => e.unpaidIn(mk) && e.amount > 0).toList()
        ..sort((a, b) => (a.dueDay == 0 ? 99 : a.dueDay).compareTo(b.dueDay == 0 ? 99 : b.dueDay)));
      if (items.isEmpty) continue;
      for (var i = 0; i < 3; i++) {
        final m = slotMinute(i);
        final when = DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
        if (!when.isAfter(now)) continue;
        final danger = sameMonth && r.level == GuardLevel.danger;
        final msg = _message(items, day, i, sameMonth ? r.balance : null, danger);
        msgs.add((when: when, title: msg.title, body: msg.body, danger: danger));
      }
    }
    await CashbookNotificationService.scheduleGuardSlots(msgs);
  }

  /// অ্যাপ চালু / রিজিউম / ব্যাকগ্রাউন্ড টাস্ক / সেভের পর ডাকা হয়: ৩ বেলার নোটিফিকেশন ঠিকঠাক বসিয়ে রাখে।
  /// [force] = সেটিংসের "পরীক্ষা" বাটন — এখনই একটা নোটিফিকেশন দেখায়।
  /// নোটিফিকেশন বারের স্থায়ী সতর্কতা হালনাগাদ করে: অবস্থা near/danger
  /// হলে দেখায়, ঠিক হয়ে গেলে (বা প্রহরী বন্ধ থাকলে) সরিয়ে দেয়।
  /// idempotent — অ্যাপ চালুতে, ব্যাকগ্রাউন্ড চেকে আর প্রতিটা ডাটা
  /// বদলের পর ডাকা হয়।
  static Future<void> syncOngoing() async {
    if (!enabled) {
      await CashbookNotificationService.cancelGuardOngoing();
      return;
    }
    final r = await assess();
    if (r.level == GuardLevel.ok) {
      await CashbookNotificationService.cancelGuardOngoing();
      return;
    }
    await CashbookNotificationService.showGuardOngoing(
      title: r.headline,
      body: r.notificationBody,
      danger: r.level == GuardLevel.danger,
    );
  }

  static Future<void> nudgeIfNeeded({bool force = false}) async {
    _listenForChanges();
    try {
      await rearmSlots();
    } catch (e) {
      debugPrint('SpendingGuard rearm failed: $e');
    }
    try {
      await syncOngoing();
    } catch (e) {
      debugPrint('SpendingGuard ongoing sync failed: $e');
    }
    if (!force) return;

    final r = await assess();
    if (!r.hasPending) {
      await CashbookNotificationService.showGuardNudge(
        title: '✅ খরচ-প্রহরী পরীক্ষা: কোনো আবশ্যিক খরচ বাকি নেই',
        body: r.essentialsLine,
        danger: false,
      );
      return;
    }
    final msg = _message(r.unpaid, DateTime.now(), 1, r.balance, r.level == GuardLevel.danger);
    await CashbookNotificationService.showGuardNudge(
      title: msg.title,
      body: msg.body,
      danger: r.level == GuardLevel.danger,
    );
  }
}
