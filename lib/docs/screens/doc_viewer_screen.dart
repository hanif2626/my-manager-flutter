import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:path_provider/path_provider.dart';
import '../../family/screens/family_ui.dart';
import '../../reminder/models/reminder.dart' show bn, formatDateBn;
import '../../widgets/app_theme.dart';
import '../models/doc_models.dart';
import '../services/doc_owners.dart';
import '../services/docs_crypto.dart';
import '../services/docs_service.dart';
import 'doc_form_sheet.dart';
import 'doc_image_viewer.dart';
import 'doc_share_sheet.dart';

/// একটা ডকুমেন্টের বিস্তারিত: তথ্য (নম্বর/রোল/রেজি. — দেখাও/কপি), মেয়াদ,
/// গ্যালারির মতো পাতার ছবি, শেয়ার/আপলোড, এডিট, মুছো।
class DocViewerScreen extends StatefulWidget {
  final VaultDoc doc;
  const DocViewerScreen({super.key, required this.doc});
  @override
  State<DocViewerScreen> createState() => _DocViewerScreenState();
}

class _DocViewerScreenState extends State<DocViewerScreen> {
  late VaultDoc _doc;
  Map<String, String> _fields = {};
  bool _showValues = false;
  final Map<String, Future<Uint8List>> _cache = {};
  // একটাই পাতা আর সেটা PDF হলে সরাসরি স্ক্রিনেই PDF দেখাই (আলাদা করে খুলতে হয় না)।
  String? _pdfPath;
  String? _pdfError;
  bool _showInfo = false;

  bool get _singlePdf => _doc.pages.length == 1 && _doc.pages.first.isPdf;

  @override
  void initState() {
    super.initState();
    _doc = widget.doc;
    _loadFields();
    _loadInlinePdf();
  }

  Future<void> _loadInlinePdf() async {
    if (!_singlePdf) {
      if (mounted) setState(() { _pdfPath = null; _pdfError = null; });
      return;
    }
    try {
      final f = await _tempFile(_doc.pages.first);
      if (mounted) setState(() { _pdfPath = f.path; _pdfError = null; });
    } catch (e) {
      if (mounted) setState(() => _pdfError = '$e');
    }
  }

  Future<void> _loadFields() async {
    final f = await DocsService.fieldsOf(_doc);
    if (mounted) setState(() => _fields = f);
  }

  Future<Uint8List> _bytes(DocPage p) => _cache.putIfAbsent(p.fileId, () => DocsCrypto.readFile(p.fileId));

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<File> _tempFile(DocPage p) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/docs_tmp_${p.fileId}.pdf');
    await f.writeAsBytes(await _bytes(p), flush: true);
    return f;
  }

  Future<void> _edit() async {
    final saved = await showDocForm(context, existing: _doc);
    if (saved) {
      final list = await DocsService.list();
      final fresh = list.where((d) => d.id == _doc.id).toList();
      if (fresh.isNotEmpty && mounted) {
        _cache.clear();
        setState(() {
          _doc = fresh.first;
          _showValues = false;
          _pdfPath = null;
        });
        _loadFields();
        _loadInlinePdf();
      }
    }
  }

  Future<void> _delete() async {
    if (!await fConfirm(context, 'মুছে ফেলবে?', '"${_doc.title}" ও এর সব ফাইল চিরতরে মুছে যাবে। ফেরানো যাবে না!')) return;
    await DocsService.delete(_doc);
    if (mounted) Navigator.pop(context, true);
  }

  Color _expColor(int d) => d < 0 ? AppTheme.red : (d <= 30 ? AppTheme.yellow : AppTheme.green);

  String _fieldLabel(DocTemplate tpl, String key) {
    for (final f in tpl.fields) {
      if (f.key == key) return f.label;
    }
    return key == 'number' ? 'ডকুমেন্ট নম্বর' : key;
  }

  @override
  Widget build(BuildContext context) {
    final cat = docCategories[_doc.category] ?? docCategories['other']!;
    final tpl = resolveTemplate(_doc);
    final d = _doc.daysToExpiry;
    final shown = <MapEntry<String, String>>[
      for (final f in tpl.fields)
        if ((_fields[f.key] ?? '').isNotEmpty) MapEntry(f.key, _fields[f.key]!),
      for (final e in _fields.entries)
        if (e.value.isNotEmpty && !tpl.fields.any((f) => f.key == e.key)) e,
    ];

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(_doc.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_doc.pages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: () => showDocShareSheet(context, _doc),
              tooltip: 'শেয়ার / আপলোড',
            ),
          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: _edit, tooltip: 'এডিট'),
          IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete, tooltip: 'মুছো'),
        ],
      ),
      body: _singlePdf ? _pdfBody(cat, tpl, d, shown) : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 40), children: [
        fCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(cat.$1, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(cat.$2, style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              fChip('👤 ${DocOwners.keyOf(_doc)}', AppTheme.accent),
              const Spacer(),
              if (d != null)
                fChip(
                  d < 0 ? 'মেয়াদ ${bn(-d)} দিন আগে শেষ' : (d == 0 ? 'আজ মেয়াদ শেষ' : 'মেয়াদ আর ${bn(d)} দিন'),
                  _expColor(d),
                ),
            ]),
            if (_doc.expiry != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('মেয়াদ শেষ: ${formatDateBn(_doc.expiry!)}',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
              ),
            if (_doc.numberEnc.isNotEmpty && shown.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('…', style: TextStyle(color: AppTheme.textMuted)),
              ),
            for (var i = 0; i < shown.length; i++) _fieldRow(tpl, shown[i], first: i == 0),
            if (_doc.note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_doc.note, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.45)),
            ],
          ]),
        ),
        if (_doc.pages.isEmpty)
          fEmpty(Icons.image_not_supported_outlined, 'কোনো ছবি নেই।\nউপরের এডিট বাটনে ট্যাপ করে ক্যামেরা বা গ্যালারি থেকে যোগ করো।')
        else ...[
          fSection('ছবি (${bn(_doc.pages.length)}টা) — ট্যাপ করলে বড় হবে, জুম ও এডিট করা যাবে'),
          _grid(),
        ],
      ]),
    );
  }

  /// একটাই PDF থাকলে: ওপরে ছোট পরিচয়-সারি (নাম/মেয়াদ; "তথ্য" ট্যাপে নম্বর-নোট), নিচে বাকি পুরো জায়গা জুড়ে PDF।
  Widget _pdfBody((String, String, List<String>) cat, DocTemplate tpl, int? d, List<MapEntry<String, String>> shown) {
    final hasInfo = shown.isNotEmpty || _doc.note.isNotEmpty || _doc.numberEnc.isNotEmpty || _doc.expiry != null;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
        child: Row(children: [
          Text(cat.$1, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Flexible(child: fChip('👤 ${DocOwners.keyOf(_doc)}', AppTheme.accent)),
          if (d != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: fChip(
                d < 0 ? 'মেয়াদ ${bn(-d)} দিন আগে শেষ' : (d == 0 ? 'আজ মেয়াদ শেষ' : 'মেয়াদ আর ${bn(d)} দিন'),
                _expColor(d),
              ),
            ),
          ],
          const Spacer(),
          if (hasInfo)
            TextButton.icon(
              onPressed: () => setState(() => _showInfo = !_showInfo),
              icon: Icon(_showInfo ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 19),
              label: const Text('তথ্য'),
            ),
        ]),
      ),
      if (_showInfo)
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.34),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: fCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_doc.expiry != null)
                  Text('মেয়াদ শেষ: ${formatDateBn(_doc.expiry!)}', style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
                for (var i = 0; i < shown.length; i++) _fieldRow(tpl, shown[i], first: i == 0),
                if (_doc.note.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(_doc.note, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.45)),
                ],
              ]),
            ),
          ),
        ),
      Expanded(
        child: _pdfError != null
            ? Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('PDF খোলা যায়নি: $_pdfError', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.red)),
              ))
            : (_pdfPath == null
                ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
                : PDFView(
                    filePath: _pdfPath!,
                    enableSwipe: true,
                    swipeHorizontal: false, // সাধারণ PDF রিডারের মতো ওপর-নিচে একটানা স্ক্রল
                    autoSpacing: false,
                    pageSnap: false,
                    pageFling: false,
                    onError: (e) {
                      if (mounted) setState(() => _pdfError = '$e');
                    },
                  )),
      ),
    ]);
  }

  Widget _fieldRow(DocTemplate tpl, MapEntry<String, String> e, {required bool first}) {
    final v = e.value;
    return Padding(
      padding: EdgeInsets.only(top: first ? 12 : 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_fieldLabel(tpl, e.key), style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        Row(children: [
          Expanded(
            child: Text(
              _showValues ? v : '•' * v.length.clamp(6, 16),
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 17,
                  letterSpacing: _showValues ? 0.5 : 2,
                  fontWeight: FontWeight.w700),
            ),
          ),
          if (first)
            IconButton(
              icon: Icon(_showValues ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
              onPressed: () => setState(() => _showValues = !_showValues),
            ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: v));
              _snack('কপি হয়েছে — ৩০ সেকেন্ড পর ক্লিপবোর্ড সাফ হবে');
              Future.delayed(const Duration(seconds: 30), () async {
                final c = await Clipboard.getData('text/plain');
                if (c?.text == v) await Clipboard.setData(const ClipboardData(text: ''));
              });
            },
          ),
        ]),
      ]),
    );
  }

  // ───────── গ্যালারির মতো গ্রিড ─────────

  Widget _grid() {
    final single = _doc.pages.length == 1;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: single ? 1 : 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: single ? 1.5 : 0.95,
      children: [for (var i = 0; i < _doc.pages.length; i++) _tile(i)],
    );
  }

  Widget _tile(int i) {
    final p = _doc.pages[i];
    return Material(
      color: AppTheme.bg2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(p),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: AppTheme.bg3,
                child: p.isPdf
                    ? Center(child: Icon(Icons.picture_as_pdf_rounded, color: AppTheme.red, size: 44))
                    : FutureBuilder<Uint8List>(
                        future: _bytes(p),
                        builder: (_, snap) {
                          if (snap.hasError) {
                            return Center(child: Text('খোলা যায়নি', style: TextStyle(color: AppTheme.red)));
                          }
                          if (!snap.hasData) {
                            return const Center(child: CircularProgressIndicator(color: AppTheme.accent));
                          }
                          return Image.memory(snap.data!, fit: BoxFit.contain, cacheWidth: 700, gaplessPlayback: true);
                        },
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Text(_doc.pageLabel(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
                Icon(Icons.open_in_full_rounded, size: 14, color: AppTheme.textMuted),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _open(DocPage p) async {
    if (p.isPdf) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => _PdfPageScreen(page: p, title: _doc.title, tempFile: _tempFile)),
      );
      return;
    }
    final imgs = _doc.pages.where((x) => !x.isPdf).toList();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocImageViewer(doc: _doc, pages: imgs, initial: imgs.indexOf(p), bytes: _bytes),
      ),
    );
    if (mounted) setState(() {}); // ভিউয়ারে এডিট হলে থাম্বনেইল নতুন হবে
  }

  @override
  void dispose() {
    // খোলা অবস্থায় বানানো সাময়িক ডিক্রিপ্টেড PDF সাফ।
    getTemporaryDirectory().then((dir) {
      try {
        for (final e in dir.listSync()) {
          if (e is File && e.uri.pathSegments.last.startsWith('docs_tmp_')) e.deleteSync();
        }
      } catch (_) {}
    });
    super.dispose();
  }
}

class _PdfPageScreen extends StatefulWidget {
  final DocPage page;
  final String title;
  final Future<File> Function(DocPage) tempFile;
  const _PdfPageScreen({required this.page, required this.title, required this.tempFile});
  @override
  State<_PdfPageScreen> createState() => _PdfPageScreenState();
}

class _PdfPageScreenState extends State<_PdfPageScreen> {
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.tempFile(widget.page).then((f) {
      if (mounted) setState(() => _path = f.path);
    }).catchError((e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Text('PDF খোলা যায়নি: $_error', style: TextStyle(color: AppTheme.red)))
          : (_path == null
              ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
              : PDFView(filePath: _path!, enableSwipe: true, swipeHorizontal: false, autoSpacing: false, pageSnap: false, pageFling: false)),
    );
  }
}
