import 'package:flutter/material.dart';
import '../db/db_helper.dart';
import '../models/idea.dart';
import '../models/project.dart';
import '../models/idea_file.dart';
import '../widgets/app_theme.dart';
import '../services/auth_service.dart';
import 'idea_detail_screen.dart';
import 'project_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  List<_SearchResult> _results = [];
  bool _searching = false;
  int _searchSeq = 0;

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    if (q.trim().isEmpty) {
      setState(() { _results = []; _searching = false; });
      return;
    }
    setState(() => _searching = true);
    final query = q.toLowerCase();
    final results = <_SearchResult>[];
    final projects = await DBHelper.getProjects();

    for (final p in projects) {
      // Search in project name
      if (p.name.toLowerCase().contains(query)) {
        results.add(_SearchResult(type: 'project', project: p, title: p.name,
            subtitle: p.description ?? 'প্রজেক্ট'));
      }
      // Search in ideas
      final ideas = await DBHelper.getIdeas(p.id!);
      for (final idea in ideas) {
        if (idea.title.toLowerCase().contains(query) ||
            (idea.description?.toLowerCase().contains(query) ?? false)) {
          results.add(_SearchResult(type: 'idea', project: p, idea: idea,
              title: idea.title, subtitle: '${p.name} → আইডিয়া'));
        }
        // Search in files
        final files = await DBHelper.getFiles(idea.id!);
        for (final f in files) {
          if (f.name.toLowerCase().contains(query) ||
              (f.isText && (f.content?.toLowerCase().contains(query) ?? false))) {
            results.add(_SearchResult(type: 'file', project: p, idea: idea,
                file: f, title: f.name,
                subtitle: '${p.name} → ${idea.title}'));
          }
        }
      }
    }
    if (mounted && seq == _searchSeq) {
      setState(() { _results = results; _searching = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style:  TextStyle(color: AppTheme.textPrimary, fontSize: 16),
          decoration:  InputDecoration(
            hintText: 'প্রজেক্ট, আইডিয়া, ফাইল খোঁজো...',
            hintStyle: TextStyle(color: AppTheme.textMuted),
            border: InputBorder.none,
          ),
          onChanged: _search,
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              onPressed: () {
                _searchSeq++;
                _ctrl.clear();
                setState(() { _results = []; _searching = false; });
              },
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : _results.isEmpty
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('🔍', style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 12),
                    Text(_ctrl.text.isEmpty
                        ? 'কী খুঁজছো লিখো...'
                        : 'কিছু পাওয়া যায়নি',
                        style:  TextStyle(color: AppTheme.textSecondary,
                            fontSize: 15)),
                  ]))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final r = _results[i];
                    return Card(
                      child: ListTile(
                        leading: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.bg3,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            r.type == 'project' ? Icons.folder_outlined
                                : r.type == 'idea' ? Icons.lightbulb_outline
                                    : Icons.insert_drive_file_outlined,
                            color: AppTheme.textSecondary, size: 18,
                          ),
                        ),
                        title: Text(r.title,
                            style:  TextStyle(
                                color: AppTheme.textPrimary, fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(r.subtitle,
                            style:  TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                        trailing: Text(
                          r.type == 'project' ? 'প্রজেক্ট'
                              : r.type == 'idea' ? 'আইডিয়া' : 'ফাইল',
                          style: TextStyle(color: AppTheme.textMuted,
                              fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        onTap: () async {
                          if (r.project.isLocked) {
                            final ok = await AuthService.authenticate(
                                reason: '"${r.project.name}" লক করা — যাচাই করো');
                            if (!ok) return;
                          }
                          if (!context.mounted) return;
                          if (r.idea != null) {
                            Navigator.push(context, MaterialPageRoute(
                                builder: (_) => IdeaDetailScreen(
                                    idea: r.idea!, project: r.project)));
                          } else {
                            Navigator.push(context, MaterialPageRoute(
                                builder: (_) => ProjectDetailScreen(
                                    project: r.project)));
                          }
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

class _SearchResult {
  final String type;
  final Project project;
  final Idea? idea;
  final IdeaFile? file;
  final String title;
  final String subtitle;
  _SearchResult({required this.type, required this.project,
      this.idea, this.file, required this.title, required this.subtitle});
}
