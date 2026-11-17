import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../widgets/app_theme.dart';
import '../models/doc_models.dart';
import '../services/doc_owners.dart';
import '../services/docs_service.dart';
import 'doc_capture_flow.dart';
import 'docs_picker.dart';

/// দ্রুত যোগের ফল: 'saved' = সেভ হয়েছে; 'classic' = বিস্তারিত
/// ফর্মে যেতে চায় (template ঠিক করা আছে); null = বাতিল।
typedef QuickAddResult = ({String action, DocTemplate? template});

/// ডকুমেন্ট যোগের সহজ পথ (ব্যবহারকারীর নির্দেশ ২০২৬-১১-১৭):
/// একই শিটে উৎস (ক্যামেরা/গ্যালারি) + ধরন বাছাই → সাথে সাথে ছবি
/// তোলা (ধাপে ধাপে ডায়ালগ ছাড়া; গ্যালারিতে সামনে+পেছনে একসাথে
/// বাছা যায়) → ছোট নিশ্চিত-ধাপ: থাম্বনেইলে পাতা যাচাই/বদলানো,
/// চিপে কার ডকুমেন্ট (নতুন নামও ওখানেই যোগ হয়), নম্বরের ঘর
/// ঐচ্ছিক। বিস্তারিত ফর্মও একই শিট থেকে বাছা যায়।
Future<QuickAddResult?> showDocQuickAdd(BuildContext context, {String? presetOwner}) {
  return showModalBottomSheet<QuickAddResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.bg2,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => _QuickAddSheet(presetOwner: presetOwner),
  );
}

class _PageSlot {
  final String label;
  NewDocPage? page;
  _PageSlot(this.label, [this.page]);
}

class _QuickAddSheet extends StatefulWidget {
  final String? presetOwner;
  const _QuickAddSheet({this.presetOwner});

  @override
  State<_QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<_QuickAddSheet> {
  ImageSource _source = ImageSource.camera;
  bool _classic = false;
  DocTemplate? _tpl;
  final List<_PageSlot> _slots = [];
  bool _capturing = false;

  final TextEditingController _titleCtrl = TextEditingController();
  final Map<String, TextEditingController> _fieldCtrls = {};
  String _owner = '';
  bool _ownerNew = false;
  final TextEditingController _ownerCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final sel = DocOwners.selected();
    _owner = widget.presetOwner ??
        ((sel != null && sel != DocOwners.all) ? sel : DocOwners.self);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _ownerCtrl.dispose();
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ───────────────────────── ছবি তোলা ─────────────────────────

  Future<void> _pickTemplate(DocTemplate t) async {
    if (_classic) {
      Navigator.pop(context, (action: 'classic', template: t));
      return;
    }
    setState(() {
      _capturing = true;
      _tpl = t;
      _error = null;
    });
    var got = <Captured>[];
    try {
      if (t.pageLabels.isNotEmpty) {
        if (_source == ImageSource.gallery) {
          // সামনে/পেছনে একসাথে বাছা যায় — ক্রম অনুযায়ী বসে।
          final list = await DocsPicker.manyImages();
          for (var i = 0; i < list.length; i++) {
            final lbl =
                i < t.pageLabels.length ? t.pageLabels[i] : 'পাতা ${bn(i + 1)}';
            got.add(Captured(lbl, list[i]));
          }
        } else {
          got = await DocCaptureFlow.run(context, ImageSource.camera,
              labels: t.pageLabels, skipPrompts: true);
        }
      } else if (_source == ImageSource.gallery) {
        final list = await DocsPicker.manyImages();
        for (var i = 0; i < list.length; i++) {
          got.add(Captured('পাতা ${bn(i + 1)}', list[i]));
        }
      } else {
        got = await DocCaptureFlow.run(context, ImageSource.camera);
      }
    } catch (e) {
      if (mounted) _snack('ছবি নেওয়া যায়নি: $e');
    }
    if (!mounted) return;
    if (got.isEmpty) {
      // কিছুই নেওয়া হয়নি — ধরন বাছাইয়েই ফিরে যাই।
      setState(() {
        _capturing = false;
        _tpl = null;
      });
      return;
    }
    _slots.clear();
    if (t.pageLabels.isNotEmpty) {
      for (final l in t.pageLabels) {
        NewDocPage? pg;
        for (final g in got) {
          if (g.label == l) {
            pg = g.page;
            break;
          }
        }
        _slots.add(_PageSlot(l, pg));
      }
      for (final g in got) {
        if (!t.pageLabels.contains(g.label)) _slots.add(_PageSlot(g.label, g.page));
      }
    } else {
      for (final g in got) {
        _slots.add(_PageSlot(g.label, g.page));
      }
    }
    _titleCtrl.text = t.isCustom ? '' : t.title;
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    _fieldCtrls.clear();
    for (final f in t.fields) {
      _fieldCtrls[f.key] = TextEditingController();
    }
    setState(() => _capturing = false);
  }

  Future<void> _slotMenu(_PageSlot slot) async {
    final filled = slot.page != null;
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(filled ? 'ক্যামেরা দিয়ে বদলাও' : 'ক্যামেরা দিয়ে তোলো'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(filled ? 'গ্যালারি থেকে বদলাও' : 'গ্যালারি থেকে নাও'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          if (filled)
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppTheme.red),
              title: const Text('পাতাটা বাদ দাও'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (act == null || !mounted) return;
    if (act == 'remove') {
      setState(() => slot.page = null);
      return;
    }
    final pg =
        await DocsPicker.image(act == 'camera' ? ImageSource.camera : ImageSource.gallery);
    if (pg == null || !mounted) return;
    setState(() {
      slot.page = pg;
      _error = null;
    });
  }

  // ───────────────────────── সেভ ─────────────────────────

  Future<void> _save() async {
    final t = _tpl!;
    final title = _titleCtrl.text.trim();
    final ownerName = _ownerNew ? _ownerCtrl.text.trim() : _owner;
    final filled = _slots.where((s) => s.page != null).toList();
    if (title.isEmpty) {
      setState(() => _error = 'ডকুমেন্টের নাম দাও');
      return;
    }
    if (ownerName.isEmpty) {
      setState(() => _error = 'কার ডকুমেন্ট তার নাম লেখো');
      return;
    }
    if (filled.isEmpty) {
      setState(() => _error = 'অন্তত একটা ছবি যোগ করো');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final d = VaultDoc(id: DocsService.newId(), title: title, category: t.category);
      d.tpl = t.key;
      d.owner = ownerName;
      await DocOwners.add(ownerName); // নতুন নাম হলে তালিকায় যোগ হয়
      await DocsService.saveEntries(
        d,
        fields: {for (final e in _fieldCtrls.entries) e.key: e.value.text.trim()},
        entries: [
          for (final s in filled) DocPageEntry(fresh: s.page, label: s.label),
        ],
      );
      if (mounted) Navigator.pop(context, (action: 'saved', template: t));
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'সেভ ব্যর্থ: $e';
        });
      }
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: _tpl == null ? _pickStage() : _confirmStage(),
        ),
      ),
    );
  }

  Widget _pickStage() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('ডকুমেন্ট যোগ করো',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      Text('কীভাবে ছবি নেবে?',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        ChoiceChip(
          label: const Text('📷 ক্যামেরা'),
          selected: _source == ImageSource.camera,
          showCheckmark: false,
          onSelected: (_) => setState(() => _source = ImageSource.camera),
        ),
        ChoiceChip(
          label: const Text('🖼️ গ্যালারি'),
          selected: _source == ImageSource.gallery,
          showCheckmark: false,
          onSelected: (_) => setState(() => _source = ImageSource.gallery),
        ),
      ]),
      const SizedBox(height: 10),
      Text('পদ্ধতি',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        ChoiceChip(
          label: const Text('⚡ দ্রুত যোগ'),
          selected: !_classic,
          showCheckmark: false,
          onSelected: (_) => setState(() => _classic = false),
        ),
        ChoiceChip(
          label: const Text('📝 বিস্তারিত ফর্ম'),
          selected: _classic,
          showCheckmark: false,
          onSelected: (_) => setState(() => _classic = true),
        ),
      ]),
      const SizedBox(height: 14),
      Text('কোন ডকুমেন্ট?',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (_capturing)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator(color: AppTheme.accent)),
        )
      else
        LayoutBuilder(builder: (_, c) {
          final w = (c.maxWidth - 10) / 2;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final t in docTemplates) SizedBox(width: w, child: _tplCard(t)),
          ]);
        }),
    ]);
  }

  Widget _tplCard(DocTemplate t) {
    return Material(
      color: AppTheme.bg3,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _pickTemplate(t),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text(t.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13, fontWeight: FontWeight.w700, height: 1.25)),
                const SizedBox(height: 3),
                Text(t.subtitle, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _confirmStage() {
    final t = _tpl!;
    final owners = DocOwners.saved();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'অন্য ধরন',
          onPressed: _saving
              ? null
              : () => setState(() {
                    _tpl = null;
                    _slots.clear();
                    _error = null;
                  }),
        ),
        Expanded(
          child: Text('নিশ্চিত করো — ${t.title}',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ]),
      const SizedBox(height: 6),
      Text('পাতাগুলো — ট্যাপ করে বদলানো/আবার তোলা যায়',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
      const SizedBox(height: 8),
      SizedBox(
        height: 128,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _slots.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) => _slotTile(_slots[i]),
        ),
      ),
      const SizedBox(height: 14),
      Text('কার ডকুমেন্ট?',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final n in owners)
          ChoiceChip(
            label: Text(n),
            selected: !_ownerNew && _owner == n,
            showCheckmark: false,
            onSelected: (_) => setState(() {
              _ownerNew = false;
              _owner = n;
            }),
          ),
        ChoiceChip(
          label: const Text('➕ নতুন নাম'),
          selected: _ownerNew,
          showCheckmark: false,
          onSelected: (_) => setState(() => _ownerNew = true),
        ),
      ]),
      if (_ownerNew) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _ownerCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'নতুন নাম লেখো',
            hintText: 'যেমন: মায়ের নাম, ছেলের নাম…',
          ),
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _titleCtrl,
        decoration: const InputDecoration(labelText: 'ডকুমেন্টের নাম'),
      ),
      for (final f in t.fields) ...[
        const SizedBox(height: 10),
        TextField(
          controller: _fieldCtrls[f.key],
          decoration: InputDecoration(labelText: '${f.label} (ঐচ্ছিক)'),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: TextStyle(color: AppTheme.red, fontSize: 13)),
      ],
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save_outlined, size: 18),
          label: const Text('সেভ করো'),
        ),
      ),
    ]);
  }

  Widget _slotTile(_PageSlot s) {
    final p = s.page;
    return Column(children: [
      InkWell(
        onTap: () => _slotMenu(s),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 84,
          height: 100,
          decoration: BoxDecoration(
            color: AppTheme.bg3,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p == null ? AppTheme.accent : AppTheme.border),
          ),
          child: p == null
              ? Icon(Icons.add_a_photo_outlined, color: AppTheme.accent, size: 28)
              : p.mime == 'application/pdf'
                  ? Icon(Icons.picture_as_pdf, color: AppTheme.textSecondary, size: 32)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Image.memory(p.bytes, width: 84, height: 100, fit: BoxFit.cover),
                    ),
        ),
      ),
      const SizedBox(height: 4),
      SizedBox(
        width: 84,
        child: Text(s.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11.5)),
      ),
    ]);
  }
}
