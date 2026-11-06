import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/bubble_picker.dart';
import '../services/bubble_window.dart';
import '../db/db_helper.dart';
import '../models/project.dart';
import '../widgets/app_theme.dart';
import '../services/export_service.dart';
import '../services/drive_service.dart';
import '../services/settings_service.dart';
import '../services/auth_service.dart';
import 'project_detail_screen.dart';
import 'project_form_screen.dart';
import 'backup_screen.dart';

/// Dashboard tab — shows the project list. Search and Settings now live
/// in the bottom navigation, so this AppBar only keeps what's needed at
/// a glance (cloud sync status, quick dark/light toggle) plus a small
/// overflow menu for the less-frequent "Import ZIP" action.
class DashboardScreen extends StatefulWidget {
  final VoidCallback? onThemeToggle;
  const DashboardScreen({super.key, this.onThemeToggle});
  @override State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Project> _projects = [];
  Map<int, Map<String, int>> _stats = {};
  bool _loading = true;
  bool _importing = false;
  bool _cloudConnected = false;

  @override
  void initState() { super.initState(); _load(); _checkCloud(); }

  Future<void> _checkCloud() async {
    // বাবলের ভেতরে Drive সাইন-ইন চেক করা হয় না (আলাদা engine,
    // নেটওয়ার্ক কল) — মেঘের আইকন অফলাইনই থাকবে; আসল অবস্থা মূল
    // অ্যাপে দেখা যাবে।
    if (BubbleWindow.isBubble) return;
    // reflects real Drive connection: filled green cloud = সিংক্‌ড, empty = অফলাইন
    bool ok = DriveService.instance.isSignedIn;
    if (!ok) ok = await DriveService.instance.signInSilently();
    if (mounted) setState(() => _cloudConnected = ok);
  }

  Future<void> _load() async {
    final projects = await DBHelper.getProjects();
    final stats = <int, Map<String, int>>{};
    for (final p in projects) {
      if (p.id != null) stats[p.id!] = await DBHelper.getProjectStats(p.id!);
    }
    if (mounted) setState(() {
      _projects = projects; _stats = stats; _loading = false;
    });
  }

  Future<void> _importProject() async {
    try {
      final result = await BubblePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: false,
      );
      if (result == null || result.files.single.path == null) return;
      setState(() => _importing = true);
      final importResult = await ExportService.importProject(
          result.files.single.path!);
      if (mounted) {
        setState(() => _importing = false);
        if (importResult.isOk) {
          _load();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ Import সফল! ${importResult.ideaCount} আইডিয়া, ${importResult.fileCount} ফাইল'),
            backgroundColor: AppTheme.green,
            duration: const Duration(seconds: 3),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ ${importResult.error ?? 'Import ব্যর্থ'}'),
            backgroundColor: AppTheme.red,
            duration: const Duration(seconds: 3),
          ));
        }
      }
    } catch (e) {
      setState(() => _importing = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.red));
    }
  }

  Future<void> _delete(Project p) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title:  Text('মুছে ফেলবে?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('"${p.name}" এবং সব ডেটা মুছে যাবে।',
            style:  TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('বাতিল')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child:  Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (confirm == true && p.id != null) {
      await DBHelper.deleteProject(p.id!);
      _load();
    }
  }

  Future<void> _duplicate(Project p) async {
    if (p.id == null) return;
    final newId = await DBHelper.duplicateProject(p.id!);
    if (mounted && newId != null) {
      _load();
      ScaffoldMessenger.of(context).showSnackBar( SnackBar(
        content: Text('✅ প্রজেক্ট কপি হয়েছে'),
        backgroundColor: AppTheme.green,
        duration: Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg2,
        title: Row(children: [
          const Text('📓', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Text('My Manager', style: AppTheme.display(size: 18)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppTheme.bg3,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.border)),
            child: Text('📁 ${_projects.length} প্রজেক্ট',
                style:  TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ),
        ]),
        automaticallyImplyLeading: false,
        actions: [
          // Quick dark/light toggle — the same setting Settings has, just
          // reachable without leaving the tab you're on.
          IconButton(
            onPressed: () async {
              final next = !SettingsService.isDark;
              await SettingsService.setDark(next);
              widget.onThemeToggle?.call();
            },
            icon: Icon(
              SettingsService.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 22, color: AppTheme.textSecondary,
            ),
            tooltip: SettingsService.isDark ? 'লাইট মোড' : 'ডার্ক মোড',
          ),
          // Drive — glanceable status, kept visible (ভরাট সবুজ = সিংক্‌ড, ফাঁকা = অফলাইন)
          IconButton(
            onPressed: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const BackupScreen()));
              _checkCloud();
            },
            icon: Icon(
              _cloudConnected ? Icons.cloud_rounded : Icons.cloud_outlined,
              size: 22,
              color: _cloudConnected ? AppTheme.green : AppTheme.textMuted,
            ),
            tooltip: _cloudConnected ? '☁️ সিংক্‌ড' : '☁️ অফলাইন — ট্যাপ করে কানেক্ট করো',
          ),
          // Everything else (Search & Settings now live in the bottom nav,
          // so only the occasional "Import ZIP" action needs a home here)
          _importing
              ? const Padding(padding: EdgeInsets.all(16),
                  child: SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: AppTheme.accent)))
              : PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 22),
                  color: AppTheme.bg2,
                  onSelected: (v) { if (v == 'import') _importProject(); },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'import', child: Row(children: [
                      Icon(Icons.download_outlined, size: 18, color: AppTheme.textSecondary),
                      SizedBox(width: 10),
                      Text('ZIP ইম্পোর্ট করো'),
                    ])),
                  ],
                ),
        ],
        bottom:  PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppTheme.border),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : _projects.isEmpty ? _emptyState()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                  itemCount: _projects.length,
                  proxyDecorator: (child, index, animation) => Material(
                    color: Colors.transparent,
                    elevation: 8,
                    shadowColor: Colors.black45,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                  onReorder: (oldIndex, newIndex) async {
                    if (newIndex > oldIndex) newIndex--;
                    setState(() {
                      final item = _projects.removeAt(oldIndex);
                      _projects.insert(newIndex, item);
                    });
                    for (int i = 0; i < _projects.length; i++) {
                      await DBHelper.updateProjectOrder(_projects[i].id!, i);
                    }
                  },
                  itemBuilder: (_, i) => Padding(
                    key: ValueKey(_projects[i].id),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _projectCard(_projects[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ProjectFormScreen()));
          _load();
        },
        backgroundColor: AppTheme.accent,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('✨ নতুন প্রজেক্ট',
            style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }

  Widget _emptyState() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text('📓', style: TextStyle(fontSize: 56)),
      const SizedBox(height: 16),
      Text('এখনো কোনো প্রজেক্ট নেই', style: AppTheme.display(size: 18)),
      const SizedBox(height: 8),
       Text('+ বাটনে চাপো অথবা ZIP import করো',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 14)),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: _importProject,
        icon: const Icon(Icons.download_outlined, color: AppTheme.accent),
        label: const Text('ZIP থেকে Import করো',
            style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppTheme.accent),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
      ),
    ]),
  );

  Future<void> _openProject(Project p) async {
    if (p.isLocked) {
      final ok = await AuthService.authenticate(
          reason: '"${p.name}" খুলতে যাচাই করো');
      if (!ok) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('যাচাই ব্যর্থ — প্রজেক্ট খোলা গেল না'),
          backgroundColor: AppTheme.danger,
        ));
        return;
      }
    }
    if (!mounted) return;
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => ProjectDetailScreen(project: p)));
    _load();
  }

  Future<void> _toggleLock(Project p) async {
    if (!p.isLocked) {
      // Turning lock ON doesn't need to re-authenticate — you're already
      // in the app. Just confirm the device actually has a way to
      // authenticate later, otherwise the lock would be unopenable.
      final canAuth = await AuthService.canAuthenticate();
      if (!canAuth) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ডিভাইসে ফিঙ্গারপ্রিন্ট/PIN সেট করা নেই, লক করা যাবে না'),
          backgroundColor: AppTheme.danger,
        ));
        return;
      }
    } else {
      // Turning lock OFF requires proving you're allowed to.
      final ok = await AuthService.authenticate(reason: 'লক খুলতে যাচাই করো');
      if (!ok) return;
    }
    await DBHelper.updateProject(p.copyWith(
        locked: p.isLocked ? 0 : 1, updatedAt: now()));
    _load();
  }

  Widget _projectCard(Project p) {
    final st = _stats[p.id] ?? {'total':0,'done':0,'doing':0,'todo':0};
    final total = st['total']!;
    final done = st['done']!;
    final progress = total > 0 ? done / total : 0.0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openProject(p),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // Monogram avatar — project identity by initial letter,
                // not by a color assignment.
                Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: AppTheme.bg3, shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.border),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    p.name.isNotEmpty ? p.name.substring(0, 1).toUpperCase() : '?',
                    style: TextStyle(color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Row(children: [
                  Flexible(child: Text(p.name, style: AppTheme.title(),
                      overflow: TextOverflow.ellipsis)),
                  if (p.isLocked) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock_outline, size: 14, color: AppTheme.textMuted),
                  ],
                ])),
                // Edit & Copy — the two most-used actions, kept visible.
                _iconBtn(Icons.edit_outlined, () async {
                  await Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ProjectFormScreen(project: p)));
                  _load();
                }, tooltip: 'এডিট'),
                const SizedBox(width: 4),
                _iconBtn(Icons.copy_outlined, () => _duplicate(p),
                    tooltip: 'কপি'),
                const SizedBox(width: 4),
                // Delete — tucked into a menu so it can't be tapped by accident.
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: AppTheme.bg3,
                        borderRadius: BorderRadius.circular(8)),
                    child:  Icon(Icons.more_vert, size: 16, color: AppTheme.textMuted),
                  ),
                  color: AppTheme.bg2,
                  onSelected: (v) {
                    if (v == 'delete') _delete(p);
                    if (v == 'lock') _toggleLock(p);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'lock', child: Row(children: [
                      Icon(p.isLocked ? Icons.lock_open_outlined : Icons.lock_outline,
                          size: 18, color: AppTheme.textSecondary),
                      const SizedBox(width: 10),
                      Text(p.isLocked ? 'লক খোলো' : 'লক করো',
                          style: TextStyle(color: AppTheme.textSecondary)),
                    ])),
                    PopupMenuItem(value: 'delete', child: Row(children: [
                      Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                      const SizedBox(width: 10),
                      Text('মুছে ফেলো', style: TextStyle(color: AppTheme.danger)),
                    ])),
                  ],
                ),
              ]),
              if (p.description != null && p.description!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(p.description!, style: AppTheme.body(),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 12),
              ClipRRect(borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress, minHeight: 5,
                  backgroundColor: AppTheme.bg3,
                  valueColor: AlwaysStoppedAnimation(AppTheme.textMuted),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                _statChip(Icons.radio_button_unchecked, '${st['todo']}'),
                const SizedBox(width: 12),
                _statChip(Icons.incomplete_circle_outlined, '${st['doing']}'),
                const SizedBox(width: 12),
                _statChip(Icons.check_circle_outline, '${st['done']}'),
                const Spacer(),
                Text('${(progress * 100).round()}%', style: AppTheme.caption(
                    weight: FontWeight.w700, color: AppTheme.textSecondary)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _statChip(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: AppTheme.textMuted),
    const SizedBox(width: 4),
    Text(text, style: AppTheme.caption()),
  ]);

  Widget _iconBtn(IconData icon, VoidCallback onTap,
      {Color? color, String? tooltip}) => Tooltip(
    message: tooltip ?? '',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: AppTheme.bg3,
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 16, color: color ?? AppTheme.textMuted),
      ),
    ),
  );
}
