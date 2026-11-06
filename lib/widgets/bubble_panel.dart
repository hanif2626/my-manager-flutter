import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart';
import '../db/db_helper.dart';
import '../models/idea.dart';
import '../models/project.dart';
import '../services/widget_service.dart';

/// বাবলের ভেতরের প্যানেল — Messenger-এর চ্যাট উইন্ডোর মতো, অন্য অ্যাপের
/// ওপরে ভাসে, পুরো অ্যাপ খোলে না।
///
/// চলে নিজের আলাদা Flutter engine-এ (`bubbleMain()` থেকে) — মূল অ্যাপের
/// মেমরি/স্টেট এখানে নেই। ডটটা নেটিভ Kotlin-এ (BubbleService), তাই
/// ড্র্যাগ/ট্যাপ/স্ন্যাপ/বন্ধ — কিছুই এই ফাইলে নেই; এখানে শুধু প্যানেলের
/// কাজ: নোট/আইডিয়া লেখা, দেখা, এডিট করা।
///
/// নেটিভের সঙ্গে কথা: MethodChannel `com.hanif.mymanager/bubble-panel`।
/// Dart → Kotlin: hidePanel / closeBubble / openApp / noteSaved।
/// Kotlin → Dart: onPanelShown (প্যানেল খুললেই তাজা ডাটা পড়ে নেওয়া)।
///
/// সেভের পর মূল অ্যাপকে আলাদা করে জানানোর দরকার নেই — মূল অ্যাপ
/// DataSync-এর ২ সেকেন্ডের পোল + resume-চেকে নিজেই পরিবর্তন ধরে ফেলে।
class BubblePanelChannel {
  static const _channel =
      MethodChannel('com.hanif.mymanager/bubble-panel');

  static Future<void> hidePanel() async {
    try {
      await _channel.invokeMethod<void>('hidePanel');
    } catch (_) {}
  }

  static Future<void> closeBubble() async {
    try {
      await _channel.invokeMethod<void>('closeBubble');
    } catch (_) {}
  }

  static Future<void> openApp() async {
    try {
      await _channel.invokeMethod<void>('openApp');
    } catch (_) {}
  }

  static Future<void> noteSaved() async {
    try {
      await _channel.invokeMethod<void>('noteSaved');
    } catch (_) {}
  }
}

class BubblePanelApp extends StatefulWidget {
  const BubblePanelApp({super.key});
  @override
  State<BubblePanelApp> createState() => _BubblePanelAppState();
}

class _BubblePanelAppState extends State<BubblePanelApp> {
  bool _loadingProjects = true;
  bool _loadingIdeas = false;
  List<Project> _projects = [];
  List<Idea> _ideas = [];
  int? _selectedProjectId;

  final _newIdeaCtrl = TextEditingController();
  Idea? _editingIdea;
  final _editTitleCtrl = TextEditingController();
  final _editDescCtrl = TextEditingController();

  // সেভের ফলাফল প্যানেলের ভেতরেই দেখানো — আগে ব্যর্থ হলে কিছুই বোঝা যেত না।
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    BubblePanelChannel._channel.setMethodCallHandler((call) async {
      if (call.method == 'onPanelShown') {
        _loadProjects();
      }
      return null;
    });
    _loadProjects();
  }

  @override
  void dispose() {
    _newIdeaCtrl.dispose();
    _editTitleCtrl.dispose();
    _editDescCtrl.dispose();
    super.dispose();
  }

  /// সবচেয়ে বেশি ব্যবহৃত প্রজেক্ট আগে — যেটা সম্ভবত দরকার সেটা
  /// প্যানেল খুললেই বাছা থাকে।
  Future<void> _loadProjects() async {
    try {
      final list = await DBHelper.getProjectsSortedByUsage();
      if (!mounted) return;
      // লক করা প্রজেক্ট বাবলে দেখানো হয় না — ছোট প্যানেল থেকে
      // ফিঙ্গারপ্রিন্ট/PIN চাওয়া যায় না, তাই নিরাপদ উত্তর হলো
      // সেগুলো না দেখানো, দুর্বল বাইপাসের ঝুঁকি না নেওয়া।
      final visible = list.where((p) => !p.isLocked).toList();
      setState(() {
        _projects = visible;
        _selectedProjectId = visible.isNotEmpty ? visible.first.id : null;
        _loadingProjects = false;
      });
      if (_selectedProjectId != null) _loadIdeas(_selectedProjectId!);
    } catch (_) {
      if (mounted) setState(() => _loadingProjects = false);
    }
  }

  Future<void> _loadIdeas(int projectId) async {
    setState(() => _loadingIdeas = true);
    try {
      final list = await DBHelper.getIdeas(projectId);
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (mounted) setState(() {
        _ideas = list;
        _loadingIdeas = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingIdeas = false);
    }
  }

  void _selectProject(int id) {
    setState(() {
      _selectedProjectId = id;
      _editingIdea = null;
    });
    _loadIdeas(id);
  }

  void _flash(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusIsError = error;
    });
    Future.delayed(Duration(seconds: error ? 6 : 2), () {
      if (mounted && _status == msg) setState(() => _status = null);
    });
  }

  Future<void> _addIdea() async {
    final title = _newIdeaCtrl.text.trim();
    if (title.isEmpty || _selectedProjectId == null) return;
    final n = DateTime.now().millisecondsSinceEpoch;
    try {
      // একটাই ছোট insert — লম্বা ট্রানজাকশন ধরে রাখা হয় না, যাতে
      // মূল অ্যাপের engine-এর সঙ্গে SQLite লক না লাগে।
      await DBHelper.insertIdea(Idea(
        projectId: _selectedProjectId!,
        title: title,
        createdAt: n,
        updatedAt: n,
      ));
    } catch (e) {
      // সেভ ব্যর্থ হলে লেখা মুছে ফেলা হয় না — লেখাটা থাকে।
      _flash('সেভ হয়নি: $e', error: true);
      return;
    }
    _newIdeaCtrl.clear();
    _flash('✓ সেভ হয়েছে');
    try {
      await WidgetService.update();
    } catch (_) {}
    await BubblePanelChannel.noteSaved();
    _loadIdeas(_selectedProjectId!);
  }

  void _startEdit(Idea idea) {
    setState(() {
      _editingIdea = idea;
      _editTitleCtrl.text = idea.title;
      _editDescCtrl.text = idea.description ?? '';
    });
  }

  void _cancelEdit() => setState(() => _editingIdea = null);

  Future<void> _commitEdit() async {
    final idea = _editingIdea;
    if (idea == null) return;
    final title = _editTitleCtrl.text.trim();
    if (title.isEmpty) return;
    try {
      await DBHelper.updateIdea(Idea(
        id: idea.id,
        projectId: idea.projectId,
        title: title,
        description: _editDescCtrl.text.trim().isEmpty
            ? null
            : _editDescCtrl.text.trim(),
        status: idea.status,
        priority: idea.priority,
        isArchived: idea.isArchived,
        deadline: idea.deadline,
        createdAt: idea.createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      _flash('এডিট সেভ হয়নি: $e', error: true);
      return;
    }
    setState(() => _editingIdea = null);
    _flash('✓ সেভ হয়েছে');
    try {
      await WidgetService.update();
    } catch (_) {}
    await BubblePanelChannel.noteSaved();
    _loadIdeas(idea.projectId);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(
            color: AppTheme.bg2,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.border),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6)),
            ],
          ),
          padding: const EdgeInsets.all(14),
          child: _editingIdea != null
              ? _editIdeaView()
              : _loadingProjects
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.accent))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Text('⚡',
                              style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text('My Manager',
                                  style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700))),
                          _headerIcon(Icons.open_in_full, 'পুরো অ্যাপ খোলো',
                              BubblePanelChannel.openApp),
                          const SizedBox(width: 4),
                          _headerIcon(Icons.remove, 'লুকাও — বাবল থাকবে',
                              BubblePanelChannel.hidePanel),
                          const SizedBox(width: 4),
                          _headerIcon(Icons.close, 'বাবল বন্ধ করো',
                              BubblePanelChannel.closeBubble,
                              color: AppTheme.danger),
                        ]),
                        const SizedBox(height: 10),
                        if (_projects.isEmpty)
                          Expanded(
                              child: Center(
                            child: Text('আগে অ্যাপে একটা প্রজেক্ট বানাও',
                                style: TextStyle(
                                    color: AppTheme.textMuted, fontSize: 13),
                                textAlign: TextAlign.center),
                          ))
                        else ...[
                          SizedBox(
                            height: 32,
                            child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: _projects.map((p) {
                                  final sel = _selectedProjectId == p.id;
                                  return Padding(
                                    padding:
                                        const EdgeInsets.only(right: 8),
                                    child: GestureDetector(
                                      onTap: () => _selectProject(p.id!),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: sel
                                              ? AppTheme.accent
                                                  .withOpacity(0.15)
                                              : AppTheme.bg3,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                              color: sel
                                                  ? AppTheme.accent
                                                  : AppTheme.border,
                                              width: sel ? 2 : 1),
                                        ),
                                        child: Text(p.name,
                                            style: TextStyle(
                                                color: sel
                                                    ? AppTheme.accent
                                                    : AppTheme.textSecondary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600)),
                                      ),
                                    ),
                                  );
                                }).toList()),
                          ),
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(
                                child: TextField(
                              controller: _newIdeaCtrl,
                              style: TextStyle(
                                  color: AppTheme.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'নতুন নোট / আইডিয়া লিখো...',
                                hintStyle: TextStyle(
                                    color: AppTheme.textMuted, fontSize: 13),
                                filled: true,
                                fillColor: AppTheme.bg3,
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                        color: AppTheme.border)),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: const BorderSide(
                                        color: AppTheme.accent, width: 2)),
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                              ),
                              onSubmitted: (_) => _addIdea(),
                            )),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: _addIdea,
                              child: Container(
                                padding: const EdgeInsets.all(11),
                                decoration: BoxDecoration(
                                    color: AppTheme.accent,
                                    borderRadius: BorderRadius.circular(10)),
                                child: const Icon(Icons.add,
                                    color: Colors.white, size: 18),
                              ),
                            ),
                          ]),
                          if (_status != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(_status!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: _statusIsError
                                          ? AppTheme.red
                                          : AppTheme.green,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600)),
                            ),
                          const SizedBox(height: 10),
                          Text('সাম্প্রতিক আইডিয়া',
                              style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Expanded(
                            child: _loadingIdeas
                                ? const Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.accent))
                                : _ideas.isEmpty
                                    ? Center(
                                        child: Text('এখনো কোনো আইডিয়া নেই',
                                            style: TextStyle(
                                                color: AppTheme.textMuted,
                                                fontSize: 12)))
                                    : ListView.builder(
                                        itemCount: _ideas.length,
                                        itemBuilder: (_, i) =>
                                            _ideaRow(_ideas[i]),
                                      ),
                          ),
                        ],
                      ],
                    ),
        ),
      ),
    );
  }

  Widget _ideaRow(Idea idea) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.bg3,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Icon(
            idea.status == 'done'
                ? Icons.check_circle
                : idea.status == 'doing'
                    ? Icons.incomplete_circle_outlined
                    : Icons.radio_button_unchecked,
            size: 16,
            color: AppTheme.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => _startEdit(idea),
              behavior: HitTestBehavior.opaque,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(idea.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: idea.status == 'done'
                                ? AppTheme.textMuted
                                : AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            decoration: idea.status == 'done'
                                ? TextDecoration.lineThrough
                                : null)),
                    if (idea.description != null &&
                        idea.description!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(idea.description!,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textMuted, fontSize: 11)),
                      ),
                  ]),
            ),
          ),
          GestureDetector(
            onTap: () => _startEdit(idea),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.edit_note,
                  size: 18, color: AppTheme.textMuted),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _editIdeaView() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          GestureDetector(
            onTap: _cancelEdit,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.arrow_back,
                  size: 18, color: AppTheme.textMuted),
            ),
          ),
          Expanded(
              child: Text('আইডিয়া এডিট করো',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700))),
          GestureDetector(
            onTap: _commitEdit,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(8)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check, size: 14, color: Colors.white),
                SizedBox(width: 4),
                Text('আপডেট',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text('শিরোনাম',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: _editTitleCtrl,
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppTheme.bg3,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppTheme.border)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide:
                    const BorderSide(color: AppTheme.accent, width: 2)),
          ),
        ),
        const SizedBox(height: 12),
        Text('নোট / বিবরণ',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Expanded(
          child: TextField(
            controller: _editDescCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style:
                TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'এখানে বিস্তারিত লিখো বা আগের লেখা এডিট করো...',
              hintStyle:
                  TextStyle(color: AppTheme.textMuted, fontSize: 13),
              filled: true,
              fillColor: AppTheme.bg3,
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppTheme.border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: AppTheme.accent, width: 2)),
            ),
          ),
        ),
      ]);

  Widget _headerIcon(IconData icon, String tooltip, VoidCallback onTap,
          {Color? color}) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 20, color: color ?? AppTheme.textMuted),
          ),
        ),
      );
}
