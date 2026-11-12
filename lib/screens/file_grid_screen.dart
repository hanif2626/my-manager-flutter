import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import '../db/db_helper.dart';
import '../models/idea_file.dart';
import '../models/project.dart';
import '../models/idea.dart';
import '../widgets/app_theme.dart';
import '../widgets/safe_base64_image.dart';
import 'file_editor_screen.dart';
import 'image_viewer_screen.dart';
import 'copy_move_screen.dart';
import 'pdf_viewer_screen.dart';
import 'markdown_viewer_screen.dart';

class FileGridScreen extends StatefulWidget {
  final Project project;
  const FileGridScreen({super.key, required this.project});
  @override State<FileGridScreen> createState() => _FileGridScreenState();
}

class _FileGridScreenState extends State<FileGridScreen> {
  List<_FileWithIdea> _files = [];
  bool _loading = true;
  bool _isGrid = true;
  String _filter = 'all';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final ideas = await DBHelper.getIdeas(widget.project.id!);
    final result = <_FileWithIdea>[];
    for (final idea in ideas) {
      final files = await DBHelper.getFiles(idea.id!);
      for (final f in files) result.add(_FileWithIdea(file: f, idea: idea));
    }
    if (mounted) setState(() { _files = result; _loading = false; });
  }

  List<_FileWithIdea> get _filtered {
    if (_filter == 'all') return _files;
    if (_filter == 'image') return _files.where((f) => f.file.isImage).toList();
    if (_filter == 'code') return _files.where((f) => f.file.isText && !f.file.isPdf).toList();
    if (_filter == 'other') return _files.where((f) => !f.file.isImage && !f.file.isText).toList();
    return _files;
  }

  Color _extColor(String ext) {
    const map = {
      'js':Color(0xFFF7DF1E),'jsx':Color(0xFF61DAFB),'ts':Color(0xFF3178C6),
      'tsx':Color(0xFF61DAFB),'dart':Color(0xFF54C5F8),'py':Color(0xFF3776AB),
      'html':Color(0xFFE34F26),'css':Color(0xFF264DE4),'json':Color(0xFF5BC8F5),
      'yml':Color(0xFFCB171E),'md':Color(0xFF083FA1),'kt':Color(0xFF7F52FF),
      'svg':Color(0xFFFFB13B),'xml':Color(0xFFF16529),
      'png':Color(0xFF10B981),'jpg':Color(0xFF10B981),'jpeg':Color(0xFF10B981),
      'pdf':Color(0xFFEF4444),'apk':Color(0xFF4CAF50),'zip':Color(0xFF9C27B0),
      'mp3':Color(0xFFFF9800),'mp4':Color(0xFF2196F3),
    };
    return map[ext] ?? AppTheme.textSecondary;
  }

  Future<void> _shareFile(IdeaFile file) async {
    if (file.content == null) return;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${file.name}');
    if (file.isText) await f.writeAsString(file.content!);
    else { try { await f.writeAsBytes(base64Decode(file.content!)); } catch (_) {} }
    await Share.shareXFiles([XFile(f.path)], text: file.name);
  }

  void _showFileMenu(IdeaFile file, Idea idea) {
    showModalBottomSheet(
      context: context, backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(
            color: AppTheme.border, borderRadius: BorderRadius.circular(2))),
        Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(file.name, style:  TextStyle(color: AppTheme.textPrimary,
              fontWeight: FontWeight.w700, fontFamily: 'monospace', fontSize: 14)),
          Text('${idea.title} • ${file.sizeLabel}',
              style:  TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ])),
        if (file.isText)
          _tile(Icons.edit_outlined, 'এডিট করো', AppTheme.accent, () async {
            Navigator.pop(context);
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => FileEditorScreen(file: file)));
            _load();
          }),
        if (file.isText)
          _tile(Icons.copy_outlined, 'কোড কপি', AppTheme.textSecondary, () {
            Navigator.pop(context);
            Clipboard.setData(ClipboardData(text: file.content ?? ''));
            ScaffoldMessenger.of(context).showSnackBar( SnackBar(
                content: Text('কপি হয়েছে!'), backgroundColor: AppTheme.green,
                duration: Duration(seconds: 2)));
          }),
        if (file.isImage)
          _tile(Icons.image_outlined, 'ছবি দেখো', AppTheme.accent, () async {
            Navigator.pop(context);
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => ImageViewerScreen(file: file)));
          }),
        if (file.isPdf)
          _tile(Icons.picture_as_pdf_outlined, 'PDF দেখো (In-App)', AppTheme.red, () async {
            Navigator.pop(context);
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => PdfViewerScreen(file: file)));
          }),
        if (file.ext == 'md')
          _tile(Icons.auto_awesome_outlined, 'Markdown Render করো', AppTheme.accent, () async {
            Navigator.pop(context);
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => MarkdownViewerScreen(file: file)));
          }),
        _tile(Icons.copy_all_outlined, 'Copy To...', AppTheme.green, () async {
          Navigator.pop(context);
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => CopyMoveScreen(file: file, mode: 'copy',
                  currentIdeaId: idea.id!)));
          _load();
        }),
        _tile(Icons.share_outlined, 'শেয়ার', AppTheme.textSecondary,
            () { Navigator.pop(context); _shareFile(file); }),
        _tile(Icons.delete_outline, 'মুছো', AppTheme.red, () async {
          Navigator.pop(context);
          final confirm = await showDialog<bool>(context: context,
            builder: (_) => AlertDialog(
              backgroundColor: AppTheme.bg3,
              title:  Text('মুছবে?', style: TextStyle(color: AppTheme.textPrimary)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
                TextButton(onPressed: () => Navigator.pop(context, true),
                    child:  Text('মুছো', style: TextStyle(color: AppTheme.red))),
              ],
            ),
          );
          if (confirm == true && file.id != null) {
            await DBHelper.deleteFile(file.id!);
            _load();
          }
        }),
        const SizedBox(height: 8),
      ])),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
           Text('সব ফাইল', style: TextStyle(
              color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
          Text(widget.project.name, style:  TextStyle(
              color: AppTheme.textSecondary, fontSize: 12)),
        ]),
        actions: [
          IconButton(
            onPressed: () => setState(() => _isGrid = !_isGrid),
            icon: Icon(_isGrid ? Icons.list_outlined : Icons.grid_view_outlined,
                color: AppTheme.textSecondary),
            tooltip: _isGrid ? 'List View' : 'Grid View',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : Column(children: [
              // Filter bar
              Container(
                color: AppTheme.bg2,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(children: [
                  Text('${filtered.length} ফাইল',
                      style:  TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  const Spacer(),
                  ...['all','image','code','other'].map((f) {
                    final labels = {'all':'সব','image':'ছবি','code':'কোড','other':'অন্য'};
                    final sel = _filter == f;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _filter = f),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: sel ? AppTheme.accent.withOpacity(0.15) : AppTheme.bg3,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: sel ? AppTheme.accent : AppTheme.border),
                          ),
                          child: Text(labels[f]!, style: TextStyle(
                              color: sel ? AppTheme.accent : AppTheme.textSecondary,
                              fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    );
                  }),
                ]),
              ),
               Divider(height: 1, color: AppTheme.border),
              Expanded(
                child: filtered.isEmpty
                    ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Text('📂', style: TextStyle(fontSize: 40)),
                        const SizedBox(height: 12),
                         Text('কোনো ফাইল নেই', style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 15)),
                      ]))
                    : _isGrid ? _buildGrid(filtered) : _buildList(filtered),
              ),
            ]),
    );
  }

  Widget _buildGrid(List<_FileWithIdea> items) => GridView.builder(
    padding: const EdgeInsets.all(12),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, crossAxisSpacing: 10, mainAxisSpacing: 10,
        childAspectRatio: 0.85),
    itemCount: items.length,
    itemBuilder: (_, i) {
      final f = items[i].file;
      final idea = items[i].idea;
      final color = _extColor(f.ext);
      return GestureDetector(
        onTap: () => _showFileMenu(f, idea),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.bg2, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                child: f.isImage && f.content != null
                    ? SafeBase64Image(data: f.content!, fit: BoxFit.cover,
                        width: double.infinity,
                        fallback: _extIcon(f, color))
                    : _extIcon(f, color),
              ),
            ),
            Container(
              width: double.infinity, padding: const EdgeInsets.all(6),
              decoration:  BoxDecoration(
                  border: Border(top: BorderSide(color: AppTheme.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.name, style:  TextStyle(color: AppTheme.textPrimary,
                    fontSize: 10, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(f.sizeLabel, style:  TextStyle(
                    color: AppTheme.textMuted, fontSize: 9)),
              ]),
            ),
          ]),
        ),
      );
    },
  );

  Widget _buildList(List<_FileWithIdea> items) => ListView.separated(
    padding: const EdgeInsets.all(12),
    itemCount: items.length,
    separatorBuilder: (_, __) => const SizedBox(height: 8),
    itemBuilder: (_, i) {
      final f = items[i].file;
      final idea = items[i].idea;
      final color = _extColor(f.ext);
      return GestureDetector(
        onTap: () => _showFileMenu(f, idea),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AppTheme.bg2, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: Row(children: [
            Container(width: 42, height: 42,
              decoration: BoxDecoration(color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8)),
              clipBehavior: Clip.antiAlias,
              child: f.isImage && f.content != null
                  ? SafeBase64Image(data: f.content!, fit: BoxFit.cover,
                      fallback: _extIcon(f, color))
                  : _extIcon(f, color),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name, style:  TextStyle(color: AppTheme.textPrimary,
                  fontSize: 13, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('${idea.title} • ${f.sizeLabel}',
                  style:  TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ])),
            _vBadge('v${f.version}'),
            const SizedBox(width: 6),
             Icon(Icons.more_vert, size: 16, color: AppTheme.textMuted),
          ]),
        ),
      );
    },
  );

  Widget _extIcon(IdeaFile f, Color color) => Container(
    color: color.withOpacity(0.1),
    child: Center(child: Text(
      f.ext.isEmpty ? '?' : f.ext.toUpperCase().substring(0, f.ext.length.clamp(0, 4)),
      style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800))),
  );

  Widget _vBadge(String v) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4)),
    child: Text(v, style: const TextStyle(color: AppTheme.accent,
        fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
  );

  Widget _tile(IconData icon, String label, Color color, VoidCallback onTap) =>
      ListTile(leading: Icon(icon, color: color, size: 20),
          title: Text(label, style: TextStyle(color: color, fontSize: 14)),
          onTap: onTap, dense: true);
}

class _FileWithIdea {
  final IdeaFile file;
  final Idea idea;
  _FileWithIdea({required this.file, required this.idea});
}
