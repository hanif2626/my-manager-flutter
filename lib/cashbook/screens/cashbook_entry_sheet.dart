import '../services/spending_guard.dart';
import 'spending_guard_card.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/bubble_picker.dart';
import '../db/cashbook_db.dart';
import '../models/cashbook_entry.dart';
import '../models/cashbook_category.dart';
import '../services/cashbook_service.dart';
import '../../widgets/app_theme.dart';
import '../../widgets/safe_base64_image.dart';
import '../widgets/bangla_digit_input_formatter.dart';
import '../widgets/calculator_sheet.dart';

/// Add or edit a single জমা/খরচ entry. Pass [entry] to edit; omit it to
/// create a new one for [accountId]. Pops `true` if something was saved
/// or deleted, so the caller knows to refresh.
class CashbookEntrySheet extends StatefulWidget {
  final int accountId;
  final CashbookEntry? entry;
  /// নতুন এন্ট্রিতে শুরুতে 'in' (জমা) না 'out' (খরচ) বাছা থাকবে — উইজেট থেকে আসে।
  final String? initialType;
  const CashbookEntrySheet({super.key, required this.accountId, this.entry, this.initialType});

  static Future<bool?> show(BuildContext context,
      {required int accountId, CashbookEntry? entry, String? initialType}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CashbookEntrySheet(accountId: accountId, entry: entry, initialType: initialType),
    );
  }

  @override
  State<CashbookEntrySheet> createState() => _CashbookEntrySheetState();
}

class _CashbookEntrySheetState extends State<CashbookEntrySheet> {
  late String _type;
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _amountFocus = FocusNode();
  final _noteFocus = FocusNode();
  late DateTime _date;
  late String _category;
  bool _recurring = false;
  String? _voucherBase64;
  List<CashbookCategory> _categories = [];
  List<String> _recentIds = []; // এই ধরনে (জমা/খরচ) সাম্প্রতিক ব্যবহৃত ক্যাটাগরি, নতুন আগে
  bool _expanded = false;
  bool _touched = false; // ব্যবহারকারী নিজে ক্যাটাগরি বাছলে ডিফল্ট আর বদলাবে না

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _type = e?.type ?? widget.initialType ?? 'out';
    _amountCtrl.text = e != null ? _trimZero(e.amount) : '';
    _noteCtrl.text = e?.note ?? '';
    _date = e != null ? DateTime.parse(e.date) : DateTime.now();
    _categories = CashbookService.getCategories();
    _category = e?.category ?? (_categories.isNotEmpty ? _categories.last.id : 'other');
    _loadRecents();
    _recurring = e?.recurring ?? false;
    _voucherBase64 = e?.voucherImage;
  }

  String _trimZero(double v) =>
      !v.isFinite ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _amountFocus.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  Future<void> _openCalculator() async {
    final result = await CalculatorSheet.show(context);
    if (result != null) {
      setState(() => _amountCtrl.text = _trimZero(result));
    }
  }

  /// Smart input routing (শুধু নতুন এন্ট্রি): শিট খুললেই ফোকাস নোট
  /// বাক্সে থাকে। প্রথম অক্ষর digit (1234/১২৩৪) হলে উদ্দেশ্য টাকা —
  /// অক্ষরটা পরিমাণের ঘরে চলে যায়, ফোকাসও সেখানে (numeric কিবোর্ড
  /// আসে)। Letter (abcd/কখগঘ) হলে নোটেই লেখা চলতে থাকে।
  void _routeFirstChar(String value) {
    if (_isEdit || value.length != 1 || _amountCtrl.text.isNotEmpty) return;
    const bn = '০১২৩৪৫৬৭৮৯';
    final ch = value[0];
    final bnIdx = bn.indexOf(ch);
    String? digit;
    if (bnIdx != -1) {
      digit = bnIdx.toString();
    } else if (RegExp(r'[0-9.]').hasMatch(ch)) {
      digit = ch;
    }
    if (digit == null) return;
    _amountCtrl.text = digit;
    _noteCtrl.clear();
    _amountFocus.requestFocus();
  }

  Future<void> _loadRecents() async {
    try {
      final ids = await CashbookDB.recentCategoryIds(_type);
      if (!mounted) return;
      setState(() {
        _recentIds = ids;
        // নতুন এন্ট্রিতে সবচেয়ে সাম্প্রতিক ক্যাটাগরিই শুরুতে বাছা থাকে।
        if (!_isEdit && !_touched && ids.isNotEmpty && _categories.any((c) => c.id == ids.first)) {
          _category = ids.first;
        }
      });
    } catch (_) {}
  }

  /// সাম্প্রতিক ব্যবহার আগে, বাকিগুলো সংরক্ষিত ক্রমে।
  List<CashbookCategory> get _ordered {
    final byId = {for (final c in _categories) c.id: c};
    final out = <CashbookCategory>[];
    for (final id in _recentIds) {
      final c = byId.remove(id);
      if (c != null) out.add(c);
    }
    out.addAll(byId.values);
    return out;
  }

  /// প্রথম ৩টা; বাছা ক্যাটাগরি ওই ৩টার বাইরে হলে তৃতীয় জায়গায় সেটা — যাতে বাছাইটা সবসময় চোখে পড়ে।
  List<CashbookCategory> _visibleOf(List<CashbookCategory> ordered) {
    final top = ordered.take(3).toList();
    final sel = ordered.where((c) => c.id == _category);
    if (sel.isNotEmpty && top.isNotEmpty && !top.contains(sel.first)) top[top.length - 1] = sel.first;
    return top;
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          width: 36, height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.bg3,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.border),
          ),
          child: Icon(icon, size: 19, color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('নতুন ক্যাটাগরি'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('যোগ করো')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final cat = await CashbookService.addCategory(name);
      setState(() {
        _categories = CashbookService.getCategories();
        _category = cat.id;
        _touched = true;
      });
    }
  }

  Future<void> _attachVoucher() async {
    final img = await BubblePicker.pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1280);
    if (img == null) return;
    final bytes = await File(img.path).readAsBytes();
    setState(() => _voucherBase64 = base64Encode(bytes));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context, initialDate: _date,
      firstDate: DateTime(2015), lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final amount = BanglaDigitInputFormatter.parse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('সঠিক পরিমাণ লেখো')));
      return;
    }
    final n = DateTime.now().millisecondsSinceEpoch;
    final dateStr = _date.toIso8601String().substring(0, 10);
    final note = _noteCtrl.text.trim().isEmpty
        ? CashbookService.categoryById(_category).name
        : _noteCtrl.text.trim();

    // খরচ-প্রহরী: নতুন অকারণ-হতে-পারে খরচ লেখার আগে সতর্কতা (বিল/কিস্তি দেওয়ায় নয়)।
    // কিস্তি, হাসু ইত্যাদি কোনো আবশ্যিক খরচ এ মাসে বাকি থাকলে — টাকা যথেষ্ট থাকলেও — প্রতিবার
    // জানানো হয় কী কী বাকি; টাকা কমে এলে (হলুদ/লাল) আরও জোরালো।
    if (!_isEdit && _type == 'out' && !SpendingGuard.isEssentialCategory(_category) && SpendingGuard.enabled) {
      try {
        final r = await SpendingGuard.assess(extraSpend: amount, category: _category);
        if (r.hasPending && mounted) {
          final go = await showSpendingNudge(context, r, amount);
          if (go != true) {
            if (mounted) Navigator.pop(context, false); // "বাদ দিই" — এন্ট্রি না লিখেই বন্ধ
            return;
          }
        }
      } catch (_) {
        // প্রহরীর ত্রুটি যেন এন্ট্রি লেখা আটকে না দেয়
      }
    }

    if (_isEdit) {
      final updated = widget.entry!.copyWith(
        type: _type, amount: amount, category: _category, note: note,
        date: dateStr, voucherImage: _voucherBase64, recurring: _recurring, updatedAt: n,
      );
      await CashbookDB.updateEntry(updated);
    } else {
      await CashbookDB.insertEntry(CashbookEntry(
        accountId: widget.accountId, type: _type, amount: amount, category: _category,
        note: note, date: dateStr, voucherImage: _voucherBase64, recurring: _recurring,
        createdAt: n, updatedAt: n,
      ));
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('এন্ট্রি মুছে ফেলবে?'),
        content: const Text('এটা আর ফেরত পাওয়া যাবে না।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: Text('মুছে ফেলো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (confirm == true) {
      await CashbookDB.deleteEntry(widget.entry!.id!);
      if (mounted) Navigator.pop(context, true);
    }
  }

  Future<void> _duplicate() async {
    final e = widget.entry!;
    final n = DateTime.now().millisecondsSinceEpoch;
    await CashbookDB.insertEntry(CashbookEntry(
      accountId: e.accountId, type: e.type, amount: e.amount, category: e.category,
      note: e.note, date: CashbookDB.todayIso(), voucherImage: e.voucherImage,
      recurring: false, createdAt: n, updatedAt: n,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✓ আজকের তারিখে একটা কপি তৈরি হয়েছে')));
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          decoration: BoxDecoration(
            color: AppTheme.bg2,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: AppTheme.border),
          ),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(99)))),

            // type toggle
            Container(
              decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(11)),
              padding: const EdgeInsets.all(3),
              child: Row(children: [
                _typeOpt('জমা', 'in'),
                _typeOpt('খরচ', 'out'),
              ]),
            ),
            const SizedBox(height: 8),

            // amount + calculator
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  focusNode: _amountFocus,
                  autofocus: _isEdit,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [BanglaDigitInputFormatter()],
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      child: Text(_type == 'in' ? 'জমা ৳' : 'খরচ ৳',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13,
                              color: _type == 'in' ? AppTheme.green : AppTheme.red)),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                    filled: true, fillColor: AppTheme.bg3,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: AppTheme.bg3, borderRadius: BorderRadius.circular(11),
                child: InkWell(
                  onTap: _openCalculator, borderRadius: BorderRadius.circular(11),
                  child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.calculate_outlined, size: 20)),
                ),
              ),
            ]),
            const SizedBox(height: 8),

            // ক্যাটাগরি: সাম্প্রতিক ৩টা চিপ + (বাকি থাকলে) প্রসারণ আইকন + শুধু "+" আইকন।
            // বাকিগুলো প্রসারণে নিচে দেখায়; বাছা ক্যাটাগরি সবসময় ৩টার মধ্যে দৃশ্যমান।
            Builder(builder: (_) {
              final ordered = _ordered;
              final visible = _visibleOf(ordered);
              final hidden = ordered.where((c) => !visible.contains(c)).toList();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final c in visible) _catChip(c),
                  if (hidden.isNotEmpty)
                    _iconBtn(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                        () => setState(() => _expanded = !_expanded), 'আরও ক্যাটাগরি'),
                  _iconBtn(Icons.add_rounded, _addCategory, 'নতুন ক্যাটাগরি'),
                ]),
                if (_expanded && hidden.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [for (final c in hidden) _catChip(c)]),
                  ),
              ]);
            }),
            const SizedBox(height: 8),

            // note — with voucher (camera) and recurring (repeat) icons built in,
            // same idea as the reference app's camera icon inside its Notes field
            TextField(
              controller: _noteCtrl,
              focusNode: _noteFocus,
              autofocus: !_isEdit,
              onChanged: _routeFirstChar,
              decoration: InputDecoration(
                // ফাঁকা বক্স যেন টেক্সট-বক্স বলে বোঝা যায়
                hintText: 'Note (ঐচ্ছিক)',
                hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 13),
                filled: true, fillColor: AppTheme.bg3,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide.none),
                suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'ভাউচার',
                    onPressed: _attachVoucher,
                    icon: _voucherBase64 != null
                        ? ClipRRect(borderRadius: BorderRadius.circular(6),
                            child: SafeBase64Image(data: _voucherBase64!, width: 22, height: 22, fit: BoxFit.cover,
                                fallback: Icon(Icons.camera_alt_outlined, size: 19, color: AppTheme.textSecondary)))
                        : Icon(Icons.camera_alt_outlined, size: 19, color: AppTheme.textSecondary),
                  ),
                  IconButton(
                    tooltip: 'প্রতি মাসে পুনরাবৃত্তি',
                    onPressed: () => setState(() => _recurring = !_recurring),
                    icon: Icon(Icons.repeat, size: 19, color: _recurring ? AppTheme.accent : AppTheme.textSecondary),
                  ),
                  const SizedBox(width: 4),
                ]),
              ),
            ),
            const SizedBox(height: 8),

            // date — compact single row with prev/next day arrows
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(11)),
              child: Row(children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _date = _date.subtract(const Duration(days: 1))),
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: Center(
                      child: Text('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _date = _date.add(const Duration(days: 1))),
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
              ]),
            ),
            const SizedBox(height: 14),

            Row(children: [
              if (_isEdit)
                IconButton(onPressed: _delete, icon: Icon(Icons.delete_outline, color: AppTheme.red)),
              if (_isEdit)
                IconButton(onPressed: _duplicate, icon: Icon(Icons.copy_outlined, color: AppTheme.textSecondary)),
              Expanded(
                child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent, foregroundColor: Colors.white),
                  child: const Text('সেভ করো'),
                ),
              ),
            ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _typeOpt(String label, String value) {
    final selected = _type == value;
    final color = value == 'in' ? AppTheme.green : AppTheme.red;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _type = value);
          _loadRecents();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
              fontWeight: FontWeight.w700, fontSize: 13.5,
              color: selected ? Colors.white : AppTheme.textSecondary)),
        ),
      ),
    );
  }

  Widget _catChip(CashbookCategory c) {
    final selected = _category == c.id;
    return ChoiceChip(
      label: Text('${c.icon} ${c.name}', style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => setState(() {
        _category = c.id;
        _touched = true;
        _expanded = false;
      }),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selectedColor: AppTheme.accent,
      backgroundColor: AppTheme.bg3,
      labelStyle: TextStyle(color: selected ? Colors.white : AppTheme.textSecondary, fontWeight: FontWeight.w600),
      side: BorderSide.none,
    );
  }
}
