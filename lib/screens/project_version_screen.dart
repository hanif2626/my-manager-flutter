import 'package:flutter/material.dart';
import '../db/db_helper.dart';
import '../models/project.dart';
import '../widgets/app_theme.dart';

class ProjectVersionScreen extends StatefulWidget {
  final Project project;
  const ProjectVersionScreen({super.key, required this.project});
  @override State<ProjectVersionScreen> createState() => _ProjectVersionScreenState();
}

class _ProjectVersionScreenState extends State<ProjectVersionScreen> {
  List<Map<String, dynamic>> _versions = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final v = await DBHelper.getProjectVersions(widget.project.id!);
    if (mounted) setState(() { _versions = v; _loading = false; });
  }

  Future<void> _saveNewVersion() async {
    final noteCtrl = TextEditingController();
    var maxVersion = widget.project.version;
    for (final v in _versions) {
      final n = (v['version'] as int?) ?? 0;
      if (n > maxVersion) maxVersion = n;
    }
    final nextVersion = maxVersion + 1;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg3,
        title: Text('Version v$nextVersion সেভ করো',
            style:  TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: noteCtrl, autofocus: true,
          style:  TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'এই version-এ কী যোগ হলো?',
            hintStyle:  TextStyle(color: AppTheme.textMuted),
            filled: true, fillColor: AppTheme.bg4,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide:  BorderSide(color: AppTheme.border)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              await DBHelper.saveProjectVersion(
                  widget.project.id!, nextVersion, noteCtrl.text.trim());
              if (context.mounted) Navigator.pop(context);
              _load();
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent),
            child: const Text('সেভ করো'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
           Text('Version History', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
          Text(widget.project.name,
              style:  TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : Column(children: [
              // Current version banner
              Container(
                padding: const EdgeInsets.all(16),
                color: AppTheme.bg2,
                child: Row(children: [
                  Container(width: 12, height: 12,
                      decoration: BoxDecoration(color: AppTheme.textMuted, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Text('বর্তমান version: ',
                      style:  TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  Text('v${widget.project.version}',
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  GestureDetector(
                    onTap: _saveNewVersion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: AppTheme.accent, borderRadius: BorderRadius.circular(8)),
                      child: const Row(children: [
                        Icon(Icons.add, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text('নতুন Version', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
                ]),
              ),
               Divider(height: 1, color: AppTheme.border),
              Expanded(
                child: _versions.isEmpty
                    ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Text('📋', style: TextStyle(fontSize: 40)),
                        const SizedBox(height: 12),
                         Text('কোনো version history নেই',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
                        const SizedBox(height: 6),
                         Text('উপরের "নতুন Version" বাটনে চাপো',
                            style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                      ]))
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: _versions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final v = _versions[i];
                          final date = DateTime.fromMillisecondsSinceEpoch(v['created_at']);
                          final isLatest = i == 0;
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(children: [
                                Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(
                                    color: isLatest ? widget.project.color.withOpacity(0.2) : AppTheme.bg3,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: isLatest ? widget.project.color : AppTheme.border),
                                  ),
                                  child: Center(child: Text('v${v['version']}',
                                      style: TextStyle(
                                          color: isLatest ? widget.project.color : AppTheme.textSecondary,
                                          fontSize: 13, fontWeight: FontWeight.w800))),
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Text('Version ${v['version']}',
                                        style:  TextStyle(color: AppTheme.textPrimary,
                                            fontSize: 14, fontWeight: FontWeight.w600)),
                                    if (isLatest) ...[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(color: AppTheme.green.withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(4)),
                                        child:  Text('Latest', style: TextStyle(color: AppTheme.green, fontSize: 10, fontWeight: FontWeight.w700)),
                                      ),
                                    ],
                                  ]),
                                  if (v['note'] != null && v['note'].toString().isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(v['note'], style:  TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                                  ],
                                  const SizedBox(height: 4),
                                  Text('${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                                      style:  TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                                ])),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
