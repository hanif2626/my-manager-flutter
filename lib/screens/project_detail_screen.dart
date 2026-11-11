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
    if (mounted) setState(() {
      _ideas = ideas; _stats = stats; _loading = false;
      _archivedCount = archived.length;
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

  // ─────────────────────────────────────────────────────────
  // IDEA FORM — with deadline + file/camera/voice attachment
  // ─────────────────────────────────────────────────────────
  Future<void> _showIdeaForm({Idea? idea}) async {
    final nameCtrl = TextEditingController(text: idea?.title ?? '');
    final descCtrl = TextEditingController(text: idea?.description ?? '');
    String priority = idea?.priority ?? 'medium';
    DateTime? reminder;
    DateTime? deadline = idea?.deadline != null
        ? DateTime.fromMillisecondsSinceEpoch(idea!.deadline!)
        : null;
    // অতিরিক্ত অপশন (অগ্রাধিকার/Deadline/রিমাইন্ডার/ফাইল) ডিফল্টে
    // লুকানো থাকে — প্রয়োজন পড়লে ব্যবহারকারী নিজে খুলবেন।
    // শুধু Deadline আগে থেকে বসানো থাকলে খোলা অবস্থায় আসে।
    bool moreOpen = idea?.deadline != null;

    final attachments = <_Attachment>[];
    bool isRecording = false;
    String? recordPath;
    // Tracks whether the Save button was actually pressed. If the sheet
    // gets dismissed any other way (swipe down, tap outside, back
    // button), whatever was typed still gets saved automatically below —
    // nothing typed here is ever silently lost.
    bool savedExplicitly = false;
    // For a brand-new idea, the very first autosave creates the row and
    // remembers its id here so later autosaves UPDATE that same row
    // instead of inserting a new one every time.
    int? createdIdeaId;
    bool persisting = false;
    Timer? debounceTimer;

    /// Writes whatever is currently in the form to the database. Shared
    /// between the Save button, the periodic autosave-while-typing, and
    /// the autosave-on-dismiss fallback, so they can never drift out of
    /// sync.
    Future<void> persist() async {
      if (nameCtrl.text.trim().isEmpty || persisting) return;
      persisting = true;
      try {
        final n = now();
        int ideaId;
        final existingId = idea?.id ?? createdIdeaId;
        if (existingId == null) {
          ideaId = await DBHelper.insertIdea(Idea(
            projectId: widget.project.id!,
            title: nameCtrl.text.trim(),
            description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
            priority: priority,
            deadline: deadline?.millisecondsSinceEpoch,
            createdAt: n, updatedAt: n,
          ));
          createdIdeaId = ideaId;
        } else {
          ideaId = existingId;
          await DBHelper.updateIdea(Idea(
            id: ideaId,
            projectId: widget.project.id!,
            title: nameCtrl.text.trim(),
            description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
            status: idea?.status ?? 'todo',
            priority: priority,
            isArchived: idea?.isArchived ?? 0,
            deadline: deadline?.millisecondsSinceEpoch,
            createdAt: idea?.createdAt ?? n,
            updatedAt: n,
          ));
        }

        if (reminder != null && reminder!.isAfter(DateTime.now())) {
          await NotificationService.scheduleNotification(
            ideaId + 1000, '💡 ${nameCtrl.text.trim()}',
            'এই আইডিয়ার কাজ করার সময় হয়েছে!', reminder!,
          );
        }

        // Attachments only need writing once, the first time they're
        // present — repeat autosaves would otherwise re-attach the same
        // files over and over.
        if (attachments.isNotEmpty) {
          for (final a in attachments) {
            await DBHelper.insertFile(IdeaFile(
              ideaId: ideaId, projectId: widget.project.id!,
              name: a.name, type: a.type,
              content: a.content, createdAt: n, updatedAt: n,
            ));
          }
          attachments.clear();
        }
      } finally {
        persisting = false;
      }
    }

    /// Debounced autosave while typing — protects against the app itself
    /// getting closed or killed mid-edit, not just the sheet being
    /// dismissed. Fires 1.5s after the last keystroke.
    void scheduleAutosave() {
      debounceTimer?.cancel();
      debounceTimer = Timer(const Duration(milliseconds: 1500), persist);
    }
    nameCtrl.addListener(scheduleAutosave);
    descCtrl.addListener(scheduleAutosave);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {

          Future<void> startRecording() async {
            final hasPermission = await _recorder.hasPermission();
            if (!hasPermission) return;
            final dir = await getTemporaryDirectory();
            recordPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
            await _recorder.start(const RecordConfig(), path: recordPath!);
            setS(() => isRecording = true);
          }

          Future<void> stopRecording() async {
            final path = await _recorder.stop();
            setS(() => isRecording = false);
            if (path != null) {
              final bytes = await File(path).readAsBytes();
              final b64 = base64Encode(bytes);
              final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
              setS(() => attachments.add(_Attachment(name: name, type: 'audio', content: b64)));
            }
          }

          Future<void> pickImage(ImageSource source) async {
            final picked = await BubblePicker.pickImage(source: source, imageQuality: 85);
            if (picked == null) return;
            final bytes = await picked.readAsBytes();
            final b64 = base64Encode(bytes);
            final ext = picked.name.split('.').last.toLowerCase();
            final name = picked.name.toLowerCase().contains('icon')
                ? picked.name : 'image_${attachments.length + 1}.$ext';
            setS(() => attachments.add(_Attachment(name: name, type: 'image', content: b64)));
          }

          Future<void> pickFile() async {
            final result = await BubblePicker.pickFiles(
                type: FileType.any, allowMultiple: true, withData: true);
            if (result == null) return;
            for (final pf in result.files) {
              final bytes = pf.bytes ?? (pf.path != null
                  ? await File(pf.path!).readAsBytes() : null);
              if (bytes == null) continue;
              final dummy = IdeaFile(ideaId: 0, projectId: 0,
                  name: pf.name, type: 'binary', createdAt: 0, updatedAt: 0);
              final isText = dummy.isText;
              final content = isText
                  ? utf8.decode(bytes, allowMalformed: true)
                  : base64Encode(bytes);
              setS(() => attachments.add(_Attachment(
                  name: pf.name, type: isText ? 'text' : 'binary', content: content)));
            }
          }

          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  Center(child: Container(width: 40, height: 4,
                      decoration: BoxDecoration(color: AppTheme.border,
                          borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 12),

                  Row(children: [
                    Text(idea == null ? '💡 নতুন আইডিয়া' : '✏️ আইডিয়া এডিট',
                        style:  TextStyle(color: AppTheme.textPrimary,
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (idea != null)
                      GestureDetector(
                        onTap: () {
                          final text = [idea.title,
                            if (idea.description != null && idea.description!.isNotEmpty)
                              idea.description!,
                          ].join('\n\n');
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context).showSnackBar(
                               SnackBar(content: Text('টেক্সট কপি হয়েছে! ✅'),
                                  backgroundColor: AppTheme.green,
                                  duration: Duration(seconds: 1)));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(color: AppTheme.bg3,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.border)),
                          child:  Row(children: [
                            Icon(Icons.copy_outlined, size: 13, color: AppTheme.textSecondary),
                            SizedBox(width: 4),
                            Text('কপি', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                          ]),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 14),

                  _field(nameCtrl, 'আইডিয়ার শিরোনাম *'),
                  const SizedBox(height: 10),
                  _field(descCtrl, 'বিবরণ (ঐচ্ছিক)...', maxLines: 3),
                  const SizedBox(height: 12),

                  // ── আরও অপশন (ডিফল্টে লুকানো) ──────────────
                  GestureDetector(
                    onTap: () => setS(() => moreOpen = !moreOpen),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.bg3,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Row(children: [
                        Icon(Icons.tune_outlined, size: 16, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text('আরও অপশন — অগ্রাধিকার, Deadline, রিমাইন্ডার, ফাইল',
                            style: TextStyle(color: AppTheme.textSecondary,
                                fontSize: 12.5, fontWeight: FontWeight.w600))),
                        Icon(moreOpen ? Icons.expand_less : Icons.expand_more,
                            size: 18, color: AppTheme.textMuted),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (moreOpen) ...[
                  // Priority
                   Text('অগ্রাধিকার:', style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(children: ['high','medium','low'].map((k) {
                    final cfg = priorityConfig[k]!;
                    final sel = priority == k;
                    return Expanded(child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => setS(() => priority = k),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: sel ? AppTheme.accent.withOpacity(0.15) : AppTheme.bg3,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: sel ? AppTheme.accent : AppTheme.border,
                                width: sel ? 2 : 1),
                          ),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(cfg['icon'] as IconData, size: 16,
                                color: sel ? AppTheme.accent : AppTheme.textSecondary),
                            const SizedBox(height: 3),
                            Text(cfg['label'] as String,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: sel ? AppTheme.accent : AppTheme.textSecondary,
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ));
                  }).toList()),
                  const SizedBox(height: 12),

                  // ── DEADLINE ────────────────────────────────
                   Text('Deadline:', style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: deadline ?? DateTime.now().add(const Duration(days: 1)),
                        firstDate: DateTime.now().subtract(const Duration(days: 1)),
                        lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                        builder: (c, child) => Theme(
                          data: ThemeData.dark().copyWith(colorScheme:
                           ColorScheme.dark(primary: Color(0xFFEF4444), surface: AppTheme.bg3)),
                          child: child!,
                        ),
                      );
                      if (d != null) setS(() => deadline = d);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: AppTheme.bg3,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: deadline != null ? const Color(0xFFEF4444) : AppTheme.border,
                            width: deadline != null ? 1.5 : 1),
                      ),
                      child: Row(children: [
                        Icon(Icons.event_outlined,
                            color: deadline != null ? const Color(0xFFEF4444) : AppTheme.textMuted,
                            size: 18),
                        const SizedBox(width: 10),
                        Text(
                          deadline != null
                              ? '${deadline!.day}/${deadline!.month}/${deadline!.year} (deadline)'
                              : 'Deadline বেছে নাও (ঐচ্ছিক)',
                          style: TextStyle(
                              color: deadline != null ? AppTheme.textPrimary : AppTheme.textMuted,
                              fontSize: 13),
                        ),
                        const Spacer(),
                        if (deadline != null)
                          GestureDetector(
                              onTap: () => setS(() => deadline = null),
                              child:  Icon(Icons.close, color: AppTheme.textMuted, size: 16)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Reminder
                   Text('রিমাইন্ডার:', style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.now().add(const Duration(days: 1)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        builder: (c, child) => Theme(
                          data: ThemeData.dark().copyWith(colorScheme:
                           ColorScheme.dark(primary: AppTheme.accent, surface: AppTheme.bg3)),
                          child: child!,
                        ),
                      );
                      if (d == null || !ctx.mounted) return;
                      final t = await showTimePicker(
                        context: ctx,
                        initialTime: const TimeOfDay(hour: 9, minute: 0),
                        builder: (c, child) => Theme(
                          data: ThemeData.dark().copyWith(colorScheme:
                           ColorScheme.dark(primary: AppTheme.accent, surface: AppTheme.bg3)),
                          child: child!,
                        ),
                      );
                      if (t == null) return;
                      setS(() => reminder = DateTime(d.year, d.month, d.day, t.hour, t.minute));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: AppTheme.bg3,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: reminder != null ? AppTheme.accent : AppTheme.border,
                            width: reminder != null ? 1.5 : 1),
                      ),
                      child: Row(children: [
                        Icon(Icons.alarm,
                            color: reminder != null ? AppTheme.accent : AppTheme.textMuted,
                            size: 18),
                        const SizedBox(width: 10),
                        Text(
                          reminder != null
                              ? '${reminder!.day}/${reminder!.month}/${reminder!.year} ${reminder!.hour}:${reminder!.minute.toString().padLeft(2,'0')}'
                              : 'তারিখ ও সময় বেছে নাও',
                          style: TextStyle(
                              color: reminder != null ? AppTheme.textPrimary : AppTheme.textMuted,
                              fontSize: 13),
                        ),
                        const Spacer(),
                        if (reminder != null)
                          GestureDetector(
                              onTap: () => setS(() => reminder = null),
                              child:  Icon(Icons.close, color: AppTheme.textMuted, size: 16)),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Attachments
                   Text('ফাইল / ছবি / ভয়েস:', style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(children: [
                    _attachBtn(icon: Icons.attach_file_outlined, label: 'ফাইল',
                        color: AppTheme.accent, onTap: pickFile),
                    const SizedBox(width: 8),
                    _attachBtn(icon: Icons.photo_library_outlined, label: 'গ্যালারি',
                        color: AppTheme.green, onTap: () => pickImage(ImageSource.gallery)),
                    const SizedBox(width: 8),
                    _attachBtn(icon: Icons.camera_alt_outlined, label: 'ক্যামেরা',
                        color: AppTheme.yellow, onTap: () => pickImage(ImageSource.camera)),
                    const SizedBox(width: 8),
                    Expanded(child: GestureDetector(
                      onTap: () => isRecording ? stopRecording() : startRecording(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: isRecording ? AppTheme.red.withOpacity(0.15) : AppTheme.bg3,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: isRecording ? AppTheme.red : AppTheme.border,
                              width: isRecording ? 2 : 1),
                        ),
                        child: Column(children: [
                          Icon(isRecording ? Icons.stop_circle : Icons.mic_outlined,
                              color: isRecording ? AppTheme.red : AppTheme.textMuted, size: 20),
                          const SizedBox(height: 3),
                          Text(isRecording ? 'Stop' : 'ভয়েস',
                              style: TextStyle(
                                  color: isRecording ? AppTheme.red : AppTheme.textMuted,
                                  fontSize: 10, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    )),
                  ]),

                  if (attachments.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...attachments.asMap().entries.map((entry) {
                      final i = entry.key; final a = entry.value;
                      final icon = a.type == 'image' ? Icons.image_outlined
                          : a.type == 'audio' ? Icons.mic
                          : Icons.insert_drive_file_outlined;
                      final color = a.type == 'image' ? AppTheme.green
                          : a.type == 'audio' ? AppTheme.red : AppTheme.accent;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: AppTheme.bg3,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: color.withOpacity(0.3))),
                        child: Row(children: [
                          Icon(icon, color: color, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(a.name,
                              style:  TextStyle(color: AppTheme.textPrimary,
                                  fontSize: 12, fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis)),
                          GestureDetector(
                            onTap: () => setS(() => attachments.removeAt(i)),
                            child:  Icon(Icons.close, color: AppTheme.textMuted, size: 16),
                          ),
                        ]),
                      );
                    }),
                  ],
                  ], // if (moreOpen)

                  const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                // ── স্টিকি সেভ/আপডেট বাটন — স্ক্রল কলামের বাইরে,
                // তাই কিবোর্ড উঠলেও সবসময় উপরে ভেসে থাকে। ──
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: BoxDecoration(
                    color: AppTheme.bg2,
                    border: Border(top: BorderSide(color: AppTheme.border)),
                  ),
                  child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
                    onPressed: () async {
                      if (nameCtrl.text.trim().isEmpty) return;
                      await persist();
                      savedExplicitly = true;
                      if (ctx.mounted) Navigator.pop(ctx);
                      _load();
                    },
                    icon: Icon(idea == null ? Icons.add : Icons.check, size: 18, color: Colors.white),
                    label: Text(
                      idea == null
                          ? 'আইডিয়া যোগ করো' + (attachments.isNotEmpty ? ' (${attachments.length} ফাইল)' : '')
                          : 'আপডেট করো',
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  )),
                ),
              ],
            ),
          );
        },
      ),
    );

    debounceTimer?.cancel();
    nameCtrl.removeListener(scheduleAutosave);
    descCtrl.removeListener(scheduleAutosave);

    // The sheet is gone now — if it was dismissed any way other than the
    // Save button (swiped down, tapped outside, back button, or the app
    // itself getting closed/backgrounded mid-edit), don't lose what was
    // typed. Auto-save it as if Save had been pressed.
    if (!savedExplicitly && nameCtrl.text.trim().isNotEmpty) {
      await persist();
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('📝 খসড়া স্বয়ংক্রিয়ভাবে সেভ হয়েছে'),
          backgroundColor: AppTheme.accent,
          duration: Duration(seconds: 2),
        ));
      }
    }
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
      backgroundColor: AppTheme.bg,
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
          color: AppTheme.bg2,
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
          color: AppTheme.bg2,
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
      ]),
      floatingActionButton: _selectMode ? null : FloatingActionButton.extended(
        onPressed: () => _showIdeaForm(),
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

  Widget _filterChip(String value, String label, Color color) {
    final sel = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _filter = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: sel ? color.withOpacity(0.15) : AppTheme.bg3,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: sel ? color : AppTheme.border),
          ),
          child: Text(label, style: TextStyle(
              color: sel ? color : AppTheme.textSecondary,
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: sel ? color.withOpacity(0.15) : AppTheme.bg3,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: sel ? color : (count > 0 ? color.withOpacity(0.5) : AppTheme.border)),
            ),
            child: Text(label, style: TextStyle(
                color: sel ? color : (count > 0 ? color : AppTheme.textSecondary),
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
    final isDueToday = idea.isDueToday;

    return GestureDetector(
      onLongPress: () {
        if (!_selectMode) {
          setState(() => _selectMode = true);
          _toggleSelect(idea);
        }
      },
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isSelected
                ? AppTheme.accent
                : isOverdue
                    ? AppTheme.red.withOpacity(0.6)
                    : AppTheme.border,
            width: isSelected || isOverdue ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              // Select checkbox OR status circle
              if (_selectMode)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.accent.withOpacity(0.2) : AppTheme.bg3,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: isSelected ? AppTheme.accent : AppTheme.border, width: 2),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 18, color: AppTheme.accent)
                      : null,
                )
              else
                GestureDetector(
                  onTap: () {
                    const next = {'todo':'doing','doing':'done','done':'todo'};
                    _updateStatus(idea, next[idea.status]!);
                  },
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.bg3,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppTheme.border, width: 2),
                    ),
                    child: Icon(
                      idea.status=='done' ? Icons.check_rounded
                          : idea.status=='doing' ? Icons.timelapse_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18, color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(idea.title,
                        style: TextStyle(
                            color: idea.status=='done' ? AppTheme.textMuted : AppTheme.textPrimary,
                            fontSize: 14, fontWeight: FontWeight.w600,
                            decoration: idea.status=='done' ? TextDecoration.lineThrough : null),
                        maxLines: 2, overflow: TextOverflow.ellipsis)),
                    if (!_selectMode)
                      GestureDetector(
                        onTap: () => _copyIdea(idea),
                        child: Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: AppTheme.bg3,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.border)),
                          child:  Icon(Icons.copy_outlined,
                              size: 18, color: AppTheme.textSecondary),
                        ),
                      ),
                  ]),
                  if (idea.description != null && idea.description!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(idea.description!, style:  TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    _badge(pc['label'] as String, pc['color'] as Color),
                    _badge(sc['label'] as String, sc['color'] as Color),
                    // Deadline badge
                    if (idea.deadline != null)
                      _deadlineBadge(idea),
                  ]),
                ],
              )),
              if (!_selectMode) ...[
                const SizedBox(width: 8),
                Column(children: [
                  _actionBtn(Icons.edit_outlined, AppTheme.accent,
                          () => _showIdeaForm(idea: idea)),
                  const SizedBox(height: 6),
                  _actionBtn(Icons.delete_outline, AppTheme.red, () => _delete(idea)),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
  }

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

class _Attachment {
  final String name, type, content;
  _Attachment({required this.name, required this.type, required this.content});
}
