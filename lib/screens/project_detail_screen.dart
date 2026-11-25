import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../services/bubble_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../db/db_helper.dart';
import '../services/data_sync.dart';
import '../models/project.dart';
import '../models/idea.dart';
import '../models/idea_file.dart';
import '../widgets/app_theme.dart';
import '../services/notification_service.dart';
import '../services/export_service.dart';
import 'idea_detail_screen.dart';
import 'idea_composer_screen.dart';
import 'project_version_screen.dart';
import 'file_grid_screen.dart';

// now() is defined in app_theme.dart (imported above) — no local
// duplicate here, to avoid "ambiguous import" errors in any screen that
// imports both this file and app_theme.dart.

const statusConfig = {
  'todo':  {'label': 'বাকি',  'icon': Icons.radio_button_unchecked, 'color': Color(0xFF6E6E78)},
  'doing': {'label': 'চলছে', 'icon': Icons.incomplete_circle_outlined, 'color': Color(0xFF6E6E78)},
  'done':  {'label': 'শেষ',  'icon': Icons.check_circle, 'color': Color(0xFF6E6E78)},
};

const priorityConfig = {
  'high':   {'label': 'জরুরি',  'icon': Icons.signal_cellular_alt, 'color': Color(0xFF6E6E78)},
  'medium': {'label': 'মাঝারি', 'icon': Icons.signal_cellular_alt_2_bar, 'color': Color(0xFF6E6E78)},
  'low':    {'label': 'কম',    'icon': Icons.signal_cellular_alt_1_bar, 'color': Color(0xFF6E6E78)},
};

class ProjectDetailScreen extends StatefulWidget {
  final Project project;
  const ProjectDetailScreen({super.key, required this.project});
  @override State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  List<Idea> _ideas = [];
  Map<String, int> _stats = {'total':0,'done':0,'doing':0,'todo':0};
  // ideaId -> {'count': ফাইল/লেখার সংখ্যা, 'hasImage': 0/1} — কার্ডে
  // "N টা লেখা/ফাইল" ও ছবি-চিহ্ন দেখানোর জন্য (ফাইলের বাইট লোড না করেই)।
  Map<int, Map<String, int>> _fileMeta = {};
  String _filter = 'all';
  String _sort = 'priority';
  bool _loading = true;
  bool _exporting = false;
  int _archivedCount = 0;
  final _recorder = AudioRecorder();

  // Multi-select state
  bool _selectMode = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
    // ভাসমান বাবল থেকে আইডিয়া যোগ/এডিট হলে খোলা তালিকা নিজে রিলোড হবে।
    DataSync.ideasChanged.addListener(_load);
  }

  @override
  void dispose() {
    DataSync.ideasChanged.removeListener(_load);
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.project.id == null) return;
    final ideas = await DBHelper.getIdeas(widget.project.id!);
    final stats = await DBHelper.getProjectStats(widget.project.id!);
    final archived = await DBHelper.getArchivedIdeas(widget.project.id!);
    final fileMeta = await DBHelper.getIdeaFileMeta(widget.project.id!);
    if (mounted) setState(() {
      _ideas = ideas; _stats = stats; _loading = false;
      _archivedCount = archived.length;
      _fileMeta = fileMeta;
      // clean up selected that no longer exist
      final ids = ideas.map((i) => i.id!).toSet();
      _selected.removeWhere((id) => !ids.contains(id));
    });
  }

  List<Idea> get _sorted {
    List<Idea> list;
    if (_filter == 'all') {
      list = List<Idea>.from(_ideas);
    } else if (_filter == 'today') {
      list = _ideas.where((i) => i.isDueToday && i.status != 'done').toList();
    } else if (_filter == 'overdue') {
      list = _ideas.where((i) => i.isOverdue).toList();
    } else {
      list = _ideas.where((i) => i.status == _filter).toList();
    }

    if (_sort == 'priority') {
      const order = {'high':0,'medium':1,'low':2};
      list.sort((a,b) => (order[a.priority]??1).compareTo(order[b.priority]??1));
    } else if (_sort == 'status') {
      const order = {'doing':0,'todo':1,'done':2};
      list.sort((a,b) => (order[a.status]??1).compareTo(order[b.status]??1));
    } else if (_sort == 'deadline') {
      list.sort((a,b) {
        if (a.deadline == null && b.deadline == null) return 0;
        if (a.deadline == null) return 1;
        if (b.deadline == null) return -1;
        return a.deadline!.compareTo(b.deadline!);
      });
    } else if (_sort == 'created') {
      list.sort((a,b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    final result = await ExportService.exportProject(widget.project);
    if (mounted) {
      setState(() => _exporting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result != null ? '📦 Export সফল!' : '❌ Export ব্যর্থ'),
        backgroundColor: result != null ? AppTheme.green : AppTheme.red,
      ));
    }
  }

  // ── BULK ACTIONS ─────────────────────────────────────
  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) _selected.clear();
    });
  }

  void _toggleSelect(Idea idea) {
    setState(() {
      if (_selected.contains(idea.id)) {
        _selected.remove(idea.id);
      } else {
        _selected.add(idea.id!);
      }
    });
  }

  void _selectAll() {
    setState(() {
      final visible = _sorted;
      if (_selected.length == visible.length) {
        _selected.clear();
      } else {
        _selected.addAll(visible.map((i) => i.id!));
      }
    });
  }

  Future<void> _bulkStatusChange() async {
    final status = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title:  Text('Status পরিবর্তন করো', style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(mainAxisSize: MainAxisSize.min, children: ['todo','doing','done'].map((s) {
          final cfg = statusConfig[s]!;
          return ListTile(
            leading: Icon(cfg['icon'] as IconData, color: AppTheme.textSecondary, size: 18),
            title: Text(cfg['label'] as String, style:  TextStyle(color: AppTheme.textPrimary)),
            onTap: () => Navigator.pop(context, s),
          );
        }).toList()),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল'))],
      ),
    );
    if (status == null) return;
    await DBHelper.bulkUpdateStatus(_selected.toList(), status);
    setState(() { _selected.clear(); _selectMode = false; });
    _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ ${_selected.length} টা idea আপডেট হয়েছে'),
      backgroundColor: AppTheme.green,
    ));
  }

  Future<void> _bulkDelete() async {
    final count = _selected.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title: Text('$count টা idea মুছবে?', style:  TextStyle(color: AppTheme.textPrimary)),
        content:  Text('এই কাজ undo করা যাবে না।', style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child:  Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (confirm != true) return;
    await DBHelper.bulkDelete(_selected.toList());
    setState(() { _selected.clear(); _selectMode = false; });
    _load();
  }

  Future<void> _bulkMove() async {
    final projects = await DBHelper.getProjects();
    final others = projects.where((p) => p.id != widget.project.id).toList();
    if (others.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar( SnackBar(
        content: Text('অন্য কোনো project নেই'),
        backgroundColor: AppTheme.red,
      ));
      return;
    }

    final target = await showDialog<Project>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title:  Text('কোন project এ নিয়ে যাবে?', style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: others.map((p) => ListTile(
            leading: Container(width: 12, height: 12,
                decoration: BoxDecoration(color: AppTheme.textMuted, shape: BoxShape.circle)),
            title: Text(p.name, style:  TextStyle(color: AppTheme.textPrimary)),
            onTap: () => Navigator.pop(context, p),
          )).toList()),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল'))],
      ),
    );
    if (target == null) return;
    await DBHelper.bulkMoveToProject(_selected.toList(), target.id!);
    setState(() { _selected.clear(); _selectMode = false; });
    _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ "${target.name}" এ move হয়েছে'),
      backgroundColor: AppTheme.green,
    ));
  }

  // ── IDEA COMPOSER ──────────────────────────────────────
  // আগের bottom-sheet ফর্মের বদলে এখন পূর্ণ-পাতার লেখার পাতা
  // (idea_composer_screen.dart): শিরোনাম + লেখা + ছবি/ফাইল +
  // অবস্থা/অগ্রাধিকার/Deadline এক পাতায়, অটো-সেভসহ।
  Future<void> _openComposer({Idea? idea}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => IdeaComposerScreen(project: widget.project, idea: idea)),
    );
    if (changed == true) _load();
  }

  void _copyIdea(Idea idea) {
    final text = [
      idea.title,
      if (idea.description != null && idea.description!.isNotEmpty) idea.description!,
    ].join('\n\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text('কপি হয়েছে! ✅'),
            backgroundColor: AppTheme.green, duration: Duration(seconds: 1)));
  }

  Future<void> _updateStatus(Idea idea, String status) async {
    if (status == 'done') {
      await DBHelper.updateIdea(idea.copyWith(status: 'done', updatedAt: now()));
      _load();
      await Future.delayed(const Duration(milliseconds: 600));
      if (idea.id != null) {
        await DBHelper.archiveIdea(idea.id!);
        _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar( SnackBar(
          content: Text('✅ Done! আর্কাইভে চলে গেছে'),
          backgroundColor: AppTheme.green, duration: Duration(seconds: 2),
        ));
      }
    } else {
      await DBHelper.updateIdea(idea.copyWith(status: status, updatedAt: now()));
      _load();
    }
  }

  Future<void> _showArchive() async {
    if (widget.project.id == null) return;
    final archived = await DBHelper.getArchivedIdeas(widget.project.id!);
    if (!mounted) return;
    showModalBottomSheet(
      context: context, backgroundColor: AppTheme.bg2, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6, minChildSize: 0.4, maxChildSize: 0.9, expand: false,
        builder: (ctx, scrollCtrl) => Column(children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: AppTheme.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
               Icon(Icons.archive_outlined, color: AppTheme.green, size: 20),
              const SizedBox(width: 8),
              Text('আর্কাইভ (${archived.length})', style:  TextStyle(
                  color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: archived.isEmpty
                ?  Center(child: Text('কোনো আর্কাইভ নেই',
                style: TextStyle(color: AppTheme.textMuted)))
                : ListView.separated(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                itemCount: archived.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final idea = archived[i];
                  final doneDate = DateTime.fromMillisecondsSinceEpoch(idea.updatedAt);
                  final dateStr = '\${doneDate.day}/\${doneDate.month}/\${doneDate.year}';
                  return Container(
                    decoration: BoxDecoration(
                      color: AppTheme.bg3,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.green.withOpacity(0.2)),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      leading: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: AppTheme.green.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child:  Icon(Icons.check_circle_rounded,
                            color: AppTheme.green, size: 20),
                      ),
                      title: Text(idea.title, style:  TextStyle(
                          color: AppTheme.textMuted, fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.lineThrough)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (idea.description != null && idea.description!.isNotEmpty)
                            Text(idea.description!, style:  TextStyle(
                                color: AppTheme.textMuted, fontSize: 11),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text('✅ Done: \$dateStr', style:  TextStyle(
                              color: AppTheme.green, fontSize: 10, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        GestureDetector(
                          onTap: () async {
                            await DBHelper.unarchiveIdea(idea.id!);
                            if (ctx.mounted) Navigator.pop(ctx);
                            _load();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.accent.withOpacity(0.4)),
                            ),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.restore, color: AppTheme.accent, size: 13),
                              SizedBox(width: 3),
                              Text('ফিরাও', style: TextStyle(
                                  color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () async {
                            await DBHelper.deleteIdea(idea.id!);
                            if (ctx.mounted) Navigator.pop(ctx);
                            _load();
                          },
                          child: Container(
                            width: 28, height: 28,
                            decoration: BoxDecoration(
                              color: AppTheme.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(color: AppTheme.red.withOpacity(0.3)),
                            ),
                            child:  Icon(Icons.delete_outline, color: AppTheme.red, size: 14),
                          ),
                        ),
                      ]),
                    ),
                  );
                }),
          ),
        ]),
      ),
    );
  }

  Future<void> _delete(Idea idea) async {
    if (idea.id == null) return;
    final confirm = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title:  Text('মুছবে?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('"${idea.title}" মুছে যাবে।',
            style:  TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child:  Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (confirm == true) { await DBHelper.deleteIdea(idea.id!); _load(); }
  }

  @override
  Widget build(BuildContext context) {
    final total = _stats['total']!;
    final done = _stats['done']!;
    final progress = total > 0 ? done / total : 0.0;
    final sorted = _sorted;
    final overdueCount = _ideas.where((i) => i.isOverdue).length;
    final todayCount = _ideas.where((i) => i.isDueToday && i.status != 'done').length;

    return Scaffold(
      backgroundColor: AppTheme.page,
      appBar: AppBar(
        title: _selectMode
            ? Text('${_selected.length} selected',
            style:  TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700))
            : Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(
              color: AppTheme.textMuted, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.project.name,
              style: AppTheme.display(size: 16),
              overflow: TextOverflow.ellipsis)),
        ]),
        leading: _selectMode
            ? IconButton(
            icon:  Icon(Icons.close, color: AppTheme.textSecondary),
            onPressed: _toggleSelectMode)
            : null,
        actions: _selectMode
            ? [
          IconButton(
            onPressed: _selectAll,
            icon: Icon(
              _selected.length == sorted.length ? Icons.deselect : Icons.select_all,
              color: AppTheme.accent, size: 22,
            ),
            tooltip: 'সব সিলেক্ট',
          ),
          if (_selected.isNotEmpty) ...[
            IconButton(
              onPressed: _bulkStatusChange,
              icon:  Icon(Icons.swap_horiz, color: AppTheme.yellow, size: 22),
              tooltip: 'Status পরিবর্তন',
            ),
            IconButton(
              onPressed: _bulkMove,
              icon: const Icon(Icons.drive_file_move_outlined, color: AppTheme.accent, size: 22),
              tooltip: 'Move to project',
            ),
            IconButton(
              onPressed: _bulkDelete,
              icon:  Icon(Icons.delete_outline, color: AppTheme.red, size: 22),
              tooltip: 'মুছো',
            ),
          ],
        ]
            : [
          IconButton(
            onPressed: _toggleSelectMode,
            icon: const Icon(Icons.checklist_outlined, size: 22),
            tooltip: 'Multi-select',
          ),
          PopupMenuButton<String>(
            color: AppTheme.bg3,
            icon:  Icon(Icons.sort, color: AppTheme.textSecondary, size: 20),
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              _menuItem('priority', Icons.flag_outlined, 'Priority অনুযায়ী'),
              _menuItem('status', Icons.timelapse, 'Status অনুযায়ী'),
              _menuItem('deadline', Icons.event_outlined, 'Deadline অনুযায়ী'),
              _menuItem('created', Icons.access_time, 'তারিখ অনুযায়ী'),
            ],
          ),
          _exporting
              ? const Padding(padding: EdgeInsets.all(12),
              child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent)))
              : IconButton(onPressed: _export,
              icon: const Icon(Icons.upload_outlined, size: 20), tooltip: 'ZIP Export'),
          IconButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => FileGridScreen(project: widget.project))),
            icon: const Icon(Icons.grid_view_outlined, size: 20), tooltip: 'সব ফাইল',
          ),
          IconButton(onPressed: _showArchive,
              icon: const Icon(Icons.archive_outlined, size: 20), tooltip: 'আর্কাইভ'),
          IconButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => ProjectVersionScreen(project: widget.project))),
            icon: const Icon(Icons.history, size: 20),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : Column(children: [
        // Stats
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          color: AppTheme.card,
          child: Column(children: [
            Row(children: [
              _statBox('মোট', total.toString(), AppTheme.textSecondary),
              _statBox('বাকি', _stats['todo'].toString(), AppTheme.textMuted),
              _statBox('চলছে', _stats['doing'].toString(), AppTheme.yellow),
              _statBox('শেষ', done.toString(), AppTheme.green),
            ]),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
               Text('অগ্রগতি', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              Text('${(progress*100).round()}%', style:  TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: progress, minHeight: 6,
                backgroundColor: AppTheme.bg3,
                valueColor: AlwaysStoppedAnimation(AppTheme.textMuted)),
            ),
          ]),
        ),
        // Filter chips
        Container(
          color: AppTheme.page,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _filterChip('all', 'সব', AppTheme.accent),
              _filterChip('todo', '⭕ বাকি', const Color(0xFF94A3B8)),
              _filterChip('doing', '⏳ চলছে', AppTheme.yellow),
              _filterChip('done', '✅ শেষ', AppTheme.green),
              // Today's tasks
              _filterChipWithBadge('today', '📅 আজকের', AppTheme.accent, todayCount),
              // Overdue
              _filterChipWithBadge('overdue', '🔥 Overdue', AppTheme.red, overdueCount),
              _archiveChip(),
            ]),
          ),
        ),
         Divider(height: 1, color: AppTheme.border),
        Expanded(
          child: sorted.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('💡', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 10),
            Text(
              _filter == 'today' ? 'আজকে কোনো deadline নেই 🎉'
                  : _filter == 'overdue' ? 'কোনো overdue নেই 🎉'
                  : 'কোনো আইডিয়া নেই',
              style:  TextStyle(color: AppTheme.textSecondary, fontSize: 15),
            ),
          ]))
              : ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _ideaCard(sorted[i]),
          ),
        ),
        // Wide add button — ডেমোর "+ নতুন আইডিয়া লিখুন"।
        if (!_selectMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: GestureDetector(
              onTap: () => _openComposer(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border, width: 1.5),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add, size: 20, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text('নতুন আইডিয়া লিখুন',
                      style: TextStyle(color: AppTheme.textSecondary,
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
      ]),
      floatingActionButton: _selectMode ? null : FloatingActionButton.extended(
        onPressed: () => _openComposer(),
        backgroundColor: AppTheme.accent,
        icon: const Icon(Icons.lightbulb_outline, color: Colors.white),
        label: const Text('💡 আইডিয়া', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }

  Widget _archiveChip() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: _showArchive,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.green.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.green.withOpacity(0.5)),
            ),
            child:  Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.archive_outlined, size: 13, color: AppTheme.green),
              SizedBox(width: 5),
              Text('📦 আর্কাইভ', style: TextStyle(
                  color: AppTheme.green, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
          if (_archivedCount > 0)
            Positioned(
              top: -6, right: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                    color: AppTheme.green, borderRadius: BorderRadius.circular(10)),
                child: Text('$_archivedCount', style: const TextStyle(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
        ]),
      ),
    );
  }

  // ডেমোর চিপ: বাছা হলে গাঢ় পটভূমি + হালকা লেখা, না হলে
  // কার্ড-রঙের পটভূমি। দুই মোডেই একইভাবে মেলে।
  Widget _filterChip(String value, String label, Color color) {
    final sel = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _filter = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: sel ? AppTheme.textPrimary : AppTheme.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: sel ? AppTheme.textPrimary : AppTheme.border),
          ),
          child: Text(label, style: TextStyle(
              color: sel ? AppTheme.page : AppTheme.textSecondary,
              fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _filterChipWithBadge(String value, String label, Color color, int count) {
    final sel = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _filter = value),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: sel ? AppTheme.textPrimary : AppTheme.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: sel ? AppTheme.textPrimary : (count > 0 ? color.withOpacity(0.5) : AppTheme.border)),
            ),
            child: Text(label, style: TextStyle(
                color: sel ? AppTheme.page : (count > 0 ? color : AppTheme.textSecondary),
                fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          if (count > 0)
            Positioned(
              top: -6, right: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                child: Text('$count', style: const TextStyle(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _ideaCard(Idea idea) {
    final sc = statusConfig[idea.status]!;
    final pc = priorityConfig[idea.priority]!;
    final isSelected = _selected.contains(idea.id);
    final isOverdue = idea.isOverdue;
    final meta = idea.id != null ? _fileMeta[idea.id!] : null;
    final fileCount = meta?['count'] ?? 0;
    final hasImage = (meta?['hasImage'] ?? 0) == 1;
    final created = DateTime.fromMillisecondsSinceEpoch(idea.createdAt);
    final dateStr = '${created.day}/${created.month}/${created.year}';

    return GestureDetector(
      onLongPress: () {
        if (!_selectMode) {
          setState(() => _selectMode = true);
          _toggleSelect(idea);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? AppTheme.accent
                : isOverdue
                    ? AppTheme.red.withOpacity(0.6)
                    : AppTheme.border,
            width: isSelected || isOverdue ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            if (_selectMode) {
              _toggleSelect(idea);
              return;
            }
            await Navigator.push(context, MaterialPageRoute(
                builder: (_) => IdeaDetailScreen(idea: idea, project: widget.project)));
            _load();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _statusPill(idea.status),
                const SizedBox(width: 6),
                _miniChip(pc['icon'] as IconData, pc['label'] as String),
                if (idea.deadline != null) ...[
                  const SizedBox(width: 6),
                  _deadlineBadge(idea),
                ],
                const Spacer(),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert, size: 18, color: AppTheme.textMuted),
                  color: AppTheme.bg2,
                  onSelected: (v) {
                    if (v == 'edit') _openComposer(idea: idea);
                    if (v == 'copy') _copyIdea(idea);
                    if (v == 'delete') _delete(idea);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit', child: Row(children: [
                      Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      const Text('এডিট'),
                    ])),
                    PopupMenuItem(value: 'copy', child: Row(children: [
                      Icon(Icons.copy_outlined, size: 16, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      const Text('কপি'),
                    ])),
                    PopupMenuItem(value: 'delete', child: Row(children: [
                      Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                      const SizedBox(width: 8),
                      Text('মুছো', style: TextStyle(color: AppTheme.danger)),
                    ])),
                  ],
                ),
              ]),
              const SizedBox(height: 8),
              Text(idea.title,
                  style: TextStyle(
                      color: idea.status == 'done' ? AppTheme.textMuted : AppTheme.textPrimary,
                      fontSize: 17, fontWeight: FontWeight.w700, height: 1.35,
                      decoration: idea.status == 'done' ? TextDecoration.lineThrough : null),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              if (idea.description != null && idea.description!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(idea.description!,
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.75),
                    maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Text(dateStr, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                const SizedBox(width: 8),
                Text('·', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                const SizedBox(width: 8),
                if (hasImage) ...[
                  Icon(Icons.image_outlined, size: 13, color: AppTheme.textMuted),
                  const SizedBox(width: 4),
                ],
                Text(fileCount > 0 ? '$fileCount টা লেখা/ফাইল' : 'শুধু লেখা',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                const Spacer(),
                if (isSelected)
                  Icon(Icons.check_circle, size: 18, color: AppTheme.accent),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _statusPill(String status) {
    final cfg = statusConfig[status]!;
    final isDone = status == 'done';
    final isDoing = status == 'doing';
    final bg = isDone
        ? AppTheme.green.withOpacity(0.12)
        : isDoing
            ? AppTheme.yellow.withOpacity(0.12)
            : AppTheme.bg3;
    final fg = isDone
        ? AppTheme.green
        : isDoing
            ? AppTheme.yellow
            : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(cfg['icon'] as IconData, size: 12, color: fg),
        const SizedBox(width: 4),
        Text(cfg['label'] as String,
            style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _miniChip(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: AppTheme.textSecondary),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _deadlineBadge(Idea idea) {
    final d = DateTime.fromMillisecondsSinceEpoch(idea.deadline!);
    final label = '📅 ${d.day}/${d.month}/${d.year}';
    if (idea.isOverdue) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AppTheme.red.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.red.withOpacity(0.5))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
           Icon(Icons.warning_amber_rounded, size: 11, color: AppTheme.red),
          const SizedBox(width: 3),
          Text('OVERDUE · $label', style:  TextStyle(
              color: AppTheme.red, fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      );
    }
    if (idea.isDueToday) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: AppTheme.yellow.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.yellow.withOpacity(0.5))),
        child: Text('আজকে deadline!', style:  TextStyle(
            color: AppTheme.yellow, fontSize: 10, fontWeight: FontWeight.w700)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: AppTheme.bg3, borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.border)),
      child: Text(label, style:  TextStyle(
          color: AppTheme.textSecondary, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }

  // ── Helpers ───────────────────────────────────────────────
  Widget _attachBtn({required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) =>
      Expanded(child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: AppTheme.bg3,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
          ]),
        ),
      ));

  PopupMenuItem<String> _menuItem(String val, IconData icon, String label) =>
      PopupMenuItem(value: val,
        child: Row(children: [
          Icon(icon, size: 16, color: _sort==val ? AppTheme.accent : AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: _sort==val ? AppTheme.accent : AppTheme.textPrimary)),
        ]),
      );

  Widget _actionBtn(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(onTap: onTap,
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.3))),
          child: Icon(icon, size: 16, color: color),
        ),
      );

  Widget _statBox(String label, String val, Color color) => Expanded(
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: AppTheme.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Text(val, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style:  TextStyle(color: AppTheme.textMuted, fontSize: 11)),
      ]),
    ),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
  );

  Widget _field(TextEditingController ctrl, String hint, {int maxLines=1}) => TextField(
    controller: ctrl, maxLines: maxLines,
    style:  TextStyle(color: AppTheme.textPrimary),
    decoration: InputDecoration(
      hintText: hint, hintStyle:  TextStyle(color: AppTheme.textMuted),
      filled: true, fillColor: AppTheme.bg3,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide:  BorderSide(color: AppTheme.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide:  BorderSide(color: AppTheme.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
  );
}
