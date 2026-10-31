import 'package:flutter/material.dart';
import '../../widgets/app_theme.dart';
import '../models/cashbook_entry.dart';
import '../services/cashbook_service.dart';

/// ক্যাশবুকের "স্টেটমেন্ট" ধাঁচের এন্ট্রি তালিকা: উপরে সব/দৈনিক/সাপ্তাহিক/মাসিক/বার্ষিক,
/// তারিখ-ভিত্তিক গ্রুপ, আলাদা "জমা" ও "খরচ" কলাম, আর প্রতিটা সারির নিচে চলতি ব্যালেন্স।
class CashbookStatementView extends StatefulWidget {
  /// এই হিসাবের সব এন্ট্রি (ফিল্টার ছাড়া) — চলতি ব্যালেন্স সঠিক রাখতে পুরোটাই লাগে।
  final List<CashbookEntry> entries;
  final void Function(CashbookEntry) onTapEntry;
  const CashbookStatementView({super.key, required this.entries, required this.onTapEntry});

  @override
  State<CashbookStatementView> createState() => _CashbookStatementViewState();
}

class _Agg {
  final String label;
  final DateTimeRange range;
  double inSum = 0;
  double outSum = 0;
  double endBalance = 0;
  _Agg(this.label, this.range);
}

class _CashbookStatementViewState extends State<CashbookStatementView> {
  String _period = 'all'; // all | day | week | month | year
  String _type = 'all'; // all | in | out  ("জমা"/"খরচ" হেডারে ট্যাপ করলে বদলায়)
  DateTimeRange? _range;

  static const _wd = ['সোম', 'মঙ্গল', 'বুধ', 'বৃহস্পতি', 'শুক্র', 'শনি', 'রবি'];
  static const _mn = [
    'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন',
    'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর'
  ];
  static const _mnShort = ['জানু', 'ফেব্রু', 'মার্চ', 'এপ্রি', 'মে', 'জুন', 'জুলা', 'আগ', 'সেপ্টে', 'অক্টো', 'নভে', 'ডিসে'];

  static String _bn(Object v) {
    const en = '0123456789';
    const bd = '০১২৩৪৫৬৭৮৯';
    var s = v.toString();
    for (var i = 0; i < 10; i++) {
      s = s.replaceAll(en[i], bd[i]);
    }
    return s;
  }

  /// টাকার অঙ্ক ইংরেজি সংখ্যায় (পরিষ্কার পড়া যায়), হাজার-কমাসহ; দশমিক থাকলে ২ ঘর।
  static String _money(double v) {
    final neg = v < 0;
    final a = v.abs();
    final whole = a.truncate();
    final frac = a - whole;
    final s = whole.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i != 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    var out = buf.toString();
    if (frac >= 0.005) out += frac.toStringAsFixed(2).substring(1);
    return neg ? '-$out' : out;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _dateLabel(DateTime d) => '${_wd[d.weekday - 1]}, ${_bn(d.day)} ${_mn[d.month - 1]} ${_bn(d.year)}';

  static String? _time(CashbookEntry e) {
    final t = DateTime.fromMillisecondsSinceEpoch(e.createdAt);
    final d = DateTime.tryParse(e.date);
    if (d == null || t.year != d.year || t.month != d.month || t.day != d.day) return null;
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${h.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static int _cmpAsc(CashbookEntry a, CashbookEntry b) {
    final d = a.date.compareTo(b.date);
    if (d != 0) return d;
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : (a.id ?? 0).compareTo(b.id ?? 0);
  }

  // সময়কালের চাবি/লেবেল/সীমা
  (String, String, DateTimeRange) _bucket(String date) {
    final d = DateTime.parse(date);
    switch (_period) {
      case 'week':
        final mon = DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));
        final sun = mon.add(const Duration(days: 6));
        return (
          _iso(mon),
          '${_bn(mon.day)} ${_mnShort[mon.month - 1]} – ${_bn(sun.day)} ${_mnShort[sun.month - 1]} ${_bn(sun.year)}',
          DateTimeRange(start: mon, end: sun)
        );
      case 'month':
        return (
          date.substring(0, 7),
          '${_mn[d.month - 1]} ${_bn(d.year)}',
          DateTimeRange(start: DateTime(d.year, d.month, 1), end: DateTime(d.year, d.month + 1, 0))
        );
      case 'year':
        return (
          date.substring(0, 4),
          _bn(d.year),
          DateTimeRange(start: DateTime(d.year, 1, 1), end: DateTime(d.year, 12, 31))
        );
      default: // day
        final day = DateTime(d.year, d.month, d.day);
        return (date, _dateLabel(day), DateTimeRange(start: day, end: day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final asc = [...widget.entries]..sort(_cmpAsc);
    final balAfter = <CashbookEntry, double>{};
    var run = 0.0;
    for (final e in asc) {
      run += e.type == 'in' ? e.amount : -e.amount;
      balAfter[e] = run;
    }
    final totalBalance = run;

    var list = widget.entries.where((e) => _type == 'all' || e.type == _type).toList();
    if (_range != null) {
      final s = _iso(_range!.start);
      final en = _iso(_range!.end);
      list = list.where((e) => e.date.compareTo(s) >= 0 && e.date.compareTo(en) <= 0).toList();
    }
    list.sort((a, b) => _cmpAsc(b, a)); // নতুন আগে

    final inSum = list.where((e) => e.type == 'in').fold<double>(0, (s, e) => s + e.amount);
    final outSum = list.where((e) => e.type == 'out').fold<double>(0, (s, e) => s + e.amount);

    return Column(children: [
      _chipsRow(),
      _totalsStrip(inSum, outSum, totalBalance),
      _tableHeader(),
      Expanded(child: list.isEmpty ? _empty() : _rows(list, balAfter, asc)),
    ]);
  }

  // ── সব / দৈনিক / সাপ্তাহিক / মাসিক / বার্ষিক ──
  Widget _chipsRow() {
    Widget chip(String label, String value) {
      final sel = _period == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => setState(() => _period = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: sel ? AppTheme.accent.withOpacity(0.16) : AppTheme.bg2,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: sel ? AppTheme.accent : AppTheme.border, width: sel ? 1.6 : 1),
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: sel ? AppTheme.accent : AppTheme.textSecondary)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              chip('সব', 'all'),
              chip('দৈনিক', 'day'),
              chip('সাপ্তাহিক', 'week'),
              chip('মাসিক', 'month'),
              chip('বার্ষিক', 'year'),
            ]),
          ),
        ),
        if (_range != null)
          GestureDetector(
            onTap: () => setState(() => _range = null),
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(99)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.date_range, size: 15, color: Colors.white),
                const SizedBox(width: 4),
                Text(
                  _range!.start == _range!.end
                      ? '${_bn(_range!.start.day)} ${_mnShort[_range!.start.month - 1]}'
                      : '${_bn(_range!.start.day)}/${_bn(_range!.start.month)}–${_bn(_range!.end.day)}/${_bn(_range!.end.month)}',
                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 3),
                const Icon(Icons.close, size: 13, color: Colors.white),
              ]),
            ),
          )
        else
          IconButton(
            tooltip: 'তারিখের সীমা',
            icon: Icon(Icons.date_range, color: AppTheme.textSecondary),
            onPressed: () async {
              final r = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2015),
                lastDate: DateTime(2100),
                initialDateRange: DateTimeRange(start: DateTime.now().subtract(const Duration(days: 30)), end: DateTime.now()),
              );
              if (r != null) setState(() => _range = r);
            },
          ),
      ]),
    );
  }

  Widget _totalsStrip(double inSum, double outSum, double balance) {
    Widget cell(String label, String value, Color c, {CrossAxisAlignment al = CrossAxisAlignment.start}) => Expanded(
          child: Column(crossAxisAlignment: al, children: [
            Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            const SizedBox(height: 2),
            Text('৳$value', style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 15.5)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        cell('মোট জমা', _money(inSum), AppTheme.green),
        cell('মোট খরচ', _money(outSum), AppTheme.red, al: CrossAxisAlignment.center),
        cell('ব্যালেন্স', _money(balance), balance >= 0 ? AppTheme.textPrimary : AppTheme.red, al: CrossAxisAlignment.end),
      ]),
    );
  }

  static const double _wIn = 84;
  static const double _wOut = 100;

  Widget _tableHeader() {
    Widget head(String label, String value, Color c, TextAlign align, double w) {
      final active = _type == value;
      return SizedBox(
        width: w,
        child: GestureDetector(
          onTap: () => setState(() => _type = active ? 'all' : value),
          child: Text(
            label,
            textAlign: align,
            style: TextStyle(
              color: c,
              fontWeight: FontWeight.w800,
              fontSize: 14,
              decoration: active ? TextDecoration.underline : TextDecoration.none,
              decorationThickness: 2,
            ),
          ),
        ),
      );
    }

    return Container(
      color: AppTheme.bg3,
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      child: Row(children: [
        Expanded(
          child: Text(_period == 'all' ? 'তারিখ' : (_period == 'day' ? 'দিন' : _period == 'week' ? 'সপ্তাহ' : _period == 'month' ? 'মাস' : 'বছর'),
              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w800, fontSize: 14)),
        ),
        head('জমা', 'in', AppTheme.green, TextAlign.center, _wIn),
        head('খরচ', 'out', AppTheme.red, TextAlign.right, _wOut),
      ]),
    );
  }

  Widget _empty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🗒️', style: TextStyle(fontSize: 34)),
          const SizedBox(height: 8),
          Text('কোনো এন্ট্রি নেই', style: AppTheme.body()),
        ]),
      );

  Widget _rows(List<CashbookEntry> list, Map<CashbookEntry, double> balAfter, List<CashbookEntry> asc) {
    if (_period != 'all') return _aggregateRows(list, balAfter, asc);

    final children = <Widget>[];
    String? lastDate;
    var shade = false;
    for (final e in list) {
      if (e.date != lastDate) {
        final d = DateTime.tryParse(e.date);
        children.add(Container(
          width: double.infinity,
          color: AppTheme.bg3.withOpacity(0.55),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Text(d == null ? e.date : _dateLabel(d),
              style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w800, fontSize: 14)),
        ));
        lastDate = e.date;
        shade = false;
      }
      children.add(_entryRow(e, balAfter[e] ?? 0, shade));
      shade = !shade;
    }
    return ListView(padding: const EdgeInsets.only(bottom: 90), children: children);
  }

  Widget _entryRow(CashbookEntry e, double balance, bool shade) {
    final cat = CashbookService.categoryById(e.category);
    final isIn = e.type == 'in';
    final title = e.note.trim().isEmpty ? cat.name : e.note.trim();
    final time = _time(e);
    final sub = [
      '${cat.icon} ${cat.name}',
      if (time != null) time,
      if (e.voucherImage != null) '📎',
      if (e.recurring) '🔁',
    ].join(' · ');
    final amountStyle = TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: isIn ? AppTheme.green : AppTheme.red);

    return InkWell(
      onTap: () => widget.onTapEntry(e),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: shade ? AppTheme.bg2.withOpacity(0.5) : null,
          border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6), width: 0.6)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w700, height: 1.25)),
                const SizedBox(height: 4),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
              ]),
            ),
          ),
          SizedBox(
            width: _wIn,
            child: Text(isIn ? _money(e.amount) : '', textAlign: TextAlign.center, style: amountStyle),
          ),
          SizedBox(
            width: _wOut,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(isIn ? ' ' : _money(e.amount), style: amountStyle),
              const SizedBox(height: 4),
              Text('ব্যালেন্স ${_money(balance)}',
                  style: TextStyle(color: balance >= 0 ? AppTheme.textMuted : AppTheme.red, fontSize: 11.5)),
            ]),
          ),
        ]),
      ),
    );
  }

  // দৈনিক/সাপ্তাহিক/মাসিক/বার্ষিক: প্রতি সময়কালের মোট জমা/খরচ ও শেষে ব্যালেন্স; ট্যাপ করলে ওই সময়কালের এন্ট্রি।
  Widget _aggregateRows(List<CashbookEntry> list, Map<CashbookEntry, double> balAfter, List<CashbookEntry> asc) {
    // প্রতি সময়কালের শেষ ব্যালেন্স — সব এন্ট্রি ধরে (ফিল্টার নির্বিশেষে)
    final endBal = <String, double>{};
    for (final e in asc) {
      endBal[_bucket(e.date).$1] = balAfter[e] ?? 0;
    }
    final groups = <String, _Agg>{};
    for (final e in list) {
      final b = _bucket(e.date);
      final g = groups.putIfAbsent(b.$1, () => _Agg(b.$2, b.$3));
      if (e.type == 'in') {
        g.inSum += e.amount;
      } else {
        g.outSum += e.amount;
      }
      g.endBalance = endBal[b.$1] ?? 0;
    }
    final children = <Widget>[];
    var shade = false;
    for (final g in groups.values) {
      children.add(InkWell(
        onTap: () => setState(() {
          _range = g.range;
          _period = 'all';
        }),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            color: shade ? AppTheme.bg2.withOpacity(0.5) : null,
            border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6), width: 0.6)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(g.label,
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.3)),
            ),
            SizedBox(
              width: _wIn,
              child: Text(g.inSum > 0 ? _money(g.inSum) : '–',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: g.inSum > 0 ? AppTheme.green : AppTheme.textMuted)),
            ),
            SizedBox(
              width: _wOut,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(g.outSum > 0 ? _money(g.outSum) : '–',
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: g.outSum > 0 ? AppTheme.red : AppTheme.textMuted)),
                const SizedBox(height: 4),
                Text('ব্যালেন্স ${_money(g.endBalance)}',
                    style: TextStyle(color: g.endBalance >= 0 ? AppTheme.textMuted : AppTheme.red, fontSize: 11.5)),
              ]),
            ),
          ]),
        ),
      ));
      shade = !shade;
    }
    return ListView(padding: const EdgeInsets.only(bottom: 90), children: children);
  }
}
