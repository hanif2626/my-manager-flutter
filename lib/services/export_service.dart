import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../db/db_helper.dart';
import '../models/project.dart';
import '../models/idea.dart';
import '../models/idea_file.dart';

class ExportService {

  static Future<String?> exportProject(Project project) async {
    try {
      final ideas = await DBHelper.getIdeas(project.id!);
      final archive = Archive();

      final projectMeta = jsonEncode({
        'id': project.id, 'name': project.name,
        'description': project.description, 'tags': project.tags,
        'color': project.colorValue, 'version': project.version,
        'exported_at': DateTime.now().toIso8601String(),
        'idea_count': ideas.length,
      });
      final metaBytes = utf8.encode(projectMeta);
      archive.addFile(ArchiveFile('_project_meta.json', metaBytes.length, metaBytes));

      for (int i = 0; i < ideas.length; i++) {
        final idea = ideas[i];
        final folder = '${i + 1}_${_safeName(idea.title)}';

        final ideaFiles = await DBHelper.getFiles(idea.id!);
        final ideaMeta = jsonEncode({
          'id': idea.id, 'title': idea.title,
          'description': idea.description, 'status': idea.status,
          'priority': idea.priority, 'created_at': idea.createdAt,
          'files': [
            for (final f in ideaFiles)
              {'name': f.name, if (f.caption != null) 'caption': f.caption},
          ],
        });
        final ideaMetaBytes = utf8.encode(ideaMeta);
        archive.addFile(ArchiveFile(
            '$folder/_idea_meta.json', ideaMetaBytes.length, ideaMetaBytes));

        final files = ideaFiles;
        for (final f in files) {
          if (f.content == null) continue;
          List<int> fileBytes;
          if (f.isText) {
            fileBytes = utf8.encode(f.content!);
          } else {
            try { fileBytes = base64Decode(f.content!); }
            catch (_) { fileBytes = utf8.encode(f.content!); }
          }
          archive.addFile(ArchiveFile(
              '$folder/${f.name}', fileBytes.length, fileBytes));
        }

        // মানুষ/AI পড়ে বোঝার মতো নির্দেশনা — ছবির ক্যাপশনসহ।
        final stLabel = {'todo': 'করা হয়নি', 'doing': 'চলছে', 'done': 'শেষ'}[idea.status] ?? idea.status;
        final prLabel = {'low': 'কম', 'medium': 'মাঝারি', 'high': 'বেশি'}[idea.priority] ?? idea.priority;
        final rd = StringBuffer()
          ..writeln('# ${idea.title}')
          ..writeln()
          ..writeln('- স্ট্যাটাস: $stLabel')
          ..writeln('- প্রায়োরিটি: $prLabel');
        if (idea.description != null && idea.description!.trim().isNotEmpty) {
          rd..writeln()..writeln('## নোট')..writeln()..writeln(idea.description);
        }
        if (files.isNotEmpty) {
          rd..writeln()..writeln('## ফাইলসমূহ')..writeln();
          for (final f in files) {
            rd.writeln('- `${f.name}`${f.isImage ? ' (ছবি)' : ''}');
            if (f.caption != null && f.caption!.trim().isNotEmpty) {
              rd.writeln('  - 💬 ক্যাপশন: ${f.caption}');
            }
          }
        }
        final rdBytes = utf8.encode(rd.toString());
        archive.addFile(ArchiveFile('$folder/README.md', rdBytes.length, rdBytes));
      }

      // ZIP-এর মূল নির্দেশনা ফাইল — খুললেই পুরো প্রজেক্ট বোঝা যাবে।
      final root = StringBuffer()
        ..writeln('# ${project.name}')
        ..writeln();
      if (project.description != null && project.description!.trim().isNotEmpty) {
        root..writeln(project.description)..writeln();
      }
      root
        ..writeln('মোট আইডিয়া: ${ideas.length}টা')
        ..writeln()
        ..writeln('## কীভাবে পড়বেন')
        ..writeln()
        ..writeln('প্রতিটা নম্বর-দেওয়া ফোল্ডার একেকটা আইডিয়া। ফোল্ডারের ভেতরের '
            'README.md ফাইলে আইডিয়ার নোট, স্ট্যাটাস আর সব ফাইলের তালিকা আছে — '
            'ছবির ক্যাপশনও সেখানেই। ছবি ও অন্যান্য ফাইল একই ফোল্ডারে নাম মিলিয়ে পাবেন.')
        ..writeln()
        ..writeln('## আইডিয়াসমূহ')
        ..writeln();
      for (int i = 0; i < ideas.length; i++) {
        root.writeln('${i + 1}. ${ideas[i].title} — ফোল্ডার: ${i + 1}_${_safeName(ideas[i].title)}');
      }
      final rootBytes = utf8.encode(root.toString());
      archive.addFile(ArchiveFile('README.md', rootBytes.length, rootBytes));

      final dir = await getTemporaryDirectory();
      final zipName = '${_safeName(project.name)}_v${project.version}.zip';
      final zipFile = File('${dir.path}/$zipName');
      final encoded = ZipEncoder().encode(archive);
      if (encoded == null) return null;
      await zipFile.writeAsBytes(encoded);
      await Share.shareXFiles([XFile(zipFile.path)],
          text: '📦 ${project.name} — My Manager Export');
      return zipFile.path;
    } catch (e) {
      return null;
    }
  }

  static Future<ImportResult> importProject(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final metaFile = archive.files
          .where((f) => f.name == '_project_meta.json' && f.isFile)
          .firstOrNull;
      if (metaFile == null) return ImportResult.noMeta;

      final metaJson = jsonDecode(utf8.decode(metaFile.content as List<int>));
      final n = DateTime.now().millisecondsSinceEpoch;

      final projectId = await DBHelper.insertProject(Project(
        name: '${metaJson['name']} (Imported)',
        description: metaJson['description'],
        colorValue: metaJson['color'] ?? 0xFF6366F1,
        tags: (metaJson['tags'] as List?)
                ?.map((e) => e.toString()).toList() ?? [],
        version: metaJson['version'] ?? 1,
        createdAt: n, updatedAt: n,
      ));

      final ideaFolders = <String>{};
      for (final f in archive.files) {
        final parts = f.name.split('/');
        if (parts.length >= 2 && parts[0] != '_project_meta.json') {
          ideaFolders.add(parts[0]);
        }
      }

      int ideaCount = 0;
      int fileCount = 0;

      for (final folder in ideaFolders.toList()..sort()) {
        final ideaMetaFile = archive.files
            .where((f) => f.name == '$folder/_idea_meta.json' && f.isFile)
            .firstOrNull;

        String ideaTitle = folder.replaceFirst(RegExp(r'^\d+_'), '');
        String? ideaDesc;
        String ideaStatus = 'todo';
        String ideaPriority = 'medium';
        final capByName = <String, String>{};

        if (ideaMetaFile != null) {
          try {
            final m = jsonDecode(utf8.decode(ideaMetaFile.content as List<int>));
            ideaTitle = m['title'] ?? ideaTitle;
            ideaDesc = m['description'];
            ideaStatus = m['status'] ?? 'todo';
            ideaPriority = m['priority'] ?? 'medium';
            final fl = m['files'];
            if (fl is List) {
              for (final x in fl) {
                if (x is Map && x['name'] != null && x['caption'] != null) {
                  capByName[x['name'].toString()] = x['caption'].toString();
                }
              }
            }
          } catch (_) {}
        }

        final ideaId = await DBHelper.insertIdea(Idea(
          projectId: projectId, title: ideaTitle, description: ideaDesc,
          status: ideaStatus, priority: ideaPriority,
          createdAt: n, updatedAt: n,
        ));
        ideaCount++;

        final ideaFiles = archive.files.where((f) =>
            f.name.startsWith('$folder/') &&
            f.isFile &&
            !f.name.endsWith('_idea_meta.json') &&
            !f.name.endsWith('README.md'));

        for (final af in ideaFiles) {
          final fileName = af.name.split('/').last;
          final dummy = IdeaFile(ideaId: ideaId, projectId: projectId,
              name: fileName, type: 'binary', createdAt: n, updatedAt: n);
          final isText = dummy.isText;
          String content;
          if (isText) {
            content = utf8.decode(af.content as List<int>, allowMalformed: true);
          } else {
            content = base64Encode(af.content as List<int>);
          }
          await DBHelper.insertFile(IdeaFile(
            ideaId: ideaId, projectId: projectId, name: fileName,
            type: isText ? 'text' : 'binary', content: content,
            caption: capByName[fileName],
            createdAt: n, updatedAt: n,
          ));
          fileCount++;
        }
      }
      return ImportResult.ok(ideaCount, fileCount);
    } catch (e) {
      return ImportResult.err(e.toString());
    }
  }

  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
          .replaceAll(RegExp(r'\s+'), '_')
          .substring(0, name.length.clamp(0, 50));
}

class ImportResult {
  final bool isOk;
  final String? error;
  final int ideaCount;
  final int fileCount;

  const ImportResult._({
    required this.isOk, this.error,
    this.ideaCount = 0, this.fileCount = 0,
  });

  static const noMeta = ImportResult._(isOk: false,
      error: 'ZIP-এ _project_meta.json নেই। My Manager-এর ZIP দাও।');

  static ImportResult ok(int ideas, int files) =>
      ImportResult._(isOk: true, ideaCount: ideas, fileCount: files);

  static ImportResult err(String e) =>
      ImportResult._(isOk: false, error: e);
}
