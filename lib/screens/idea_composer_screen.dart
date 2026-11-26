import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../db/db_helper.dart';
import '../models/idea.dart';
import '../models/idea_file.dart';
import '../models/project.dart';
import '../services/bubble_picker.dart';
import '../services/notification_service.dart';
import '../widgets/app_theme.dart';

/// আইডিয়া লেখার পাতা — ডেমো-অনুমোদিত নতুন ডিজাইন।
/// একটাই পাতা: বড় শিরোনাম, লেখার জায়গা, ছবি/ফাইল লেখার সাথেই
/// জুড়ে যায়, অবস্থা/অগ্রাধিকার/Deadline একই পাতায়। আলাদা
/// অপশন-তালিকা বা লুকানো "আরও অপশন" নেই। লিখলেই অটো-সেভ হয় —
/// শিরোনাম খালি না থাকলে কিছুই হারায় না।
class IdeaComposerScreen extends StatefulWidget {
  final Project project;
  final Idea? idea;
  const IdeaComposerScreen({super.key, required this.project, this.idea});
  @override
  State<IdeaComposerScreen> createState() => _IdeaComposerScreenState();
}

class _IdeaComposerScreenState extends State<IdeaComposerScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  String _status = 'todo';
  String _priority = 'medium';
  DateTime? _deadline;
  DateTime? _reminder;
  final _attachments = <_Attachment>[];
  List<IdeaFile> _existingFiles = [];
  bool _loadingFiles = false;
  bool _isRecording = false;
  String? _recordPath;
  final _recorder = AudioRecorder();

  String _saveState = 'লিখলেই সেভ হবে';
  bool _savedExplicitly = false;
  bool _persisting = false;
  Future<void>? _persistFuture;
  bool _changed = false;
  int? _createdIdeaId;
  int? _createdAt;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final idea = widget.idea;
    if (idea != null) {
      _titleCtrl.text = idea.title;
      _bodyCtrl.text = idea.description ?? '';
      _status = idea.status;
      _priority = idea.priority;
      _deadline = idea.deadline != null
          ? DateTime.fromMillisecondsSinceEpoch(idea.deadline!)
          : null;
      _loadExistingFiles();
    }
    _titleCtrl.addListener(_scheduleAutosave);
    _bodyCtrl.addListener(_scheduleAutosave);
  }

  Future<void> _loadExistingFiles() async {
    final idea = widget.idea;
    if (idea?.id == null) return;
    setState(() => _loadingFiles = true);
    final files = await DBHelper.getFiles(idea!.id!);
    if (mounted) setState(() { _existingFiles = files; _loadingFiles = false; });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Back gesture / back button / app backgrounded — যা লেখা হয়েছে
    // তা যেন না হারায়: সেভ বোতাম না চাপলেও লিখে রাখো।
    if (!_savedExplicitly) _persist();
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _scheduleAutosave() {
    setState(() => _saveState = 'লিখছেন…');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), _persist);
  }

  /// আগের bottom-sheet ফর্মের একই persist লজিক: প্রথম autosave-এ
  /// row তৈরি হয়, পরেরগুলো সেই row-ই আপডেট করে; attachment শুধু
  /// প্রথমবার লেখা হয়, যাতে বারবার একই ফাইল না জমে।
  Future<void> _persist() {
    if (_persistFuture != null) return _persistFuture!;
    final f = _doPersist();
    _persistFuture = f;
    return f.whenComplete(() {
      if (identical(_persistFuture, f)) _persistFuture = null;
    });
  }

  Future<void> _doPersist() async {
    if (_titleCtrl.text.trim().isEmpty || _persisting) return;
    _persisting = true;
    try {
      final n = now();
      int ideaId;
      final existingId = widget.idea?.id ?? _createdIdeaId;
      if (existingId == null) {
        ideaId = await DBHelper.insertIdea(Idea(
          projectId: widget.project.id!,
          title: _titleCtrl.text.trim(),
          description: _bodyCtrl.text.trim().isEmpty ? null : _bodyCtrl.text.trim(),
          status: _status,
          priority: _priority,
          deadline: _deadline?.millisecondsSinceEpoch,
          createdAt: n, updatedAt: n,
        ));
        _createdIdeaId = ideaId;
        _createdAt = n;
      } else {
        ideaId = existingId;
        await DBHelper.updateIdea(Idea(
          id: ideaId,
          projectId: widget.project.id!,
          title: _titleCtrl.text.trim(),
          description: _bodyCtrl.text.trim().isEmpty ? null : _bodyCtrl.text.trim(),
          status: _status,
          priority: _priority,
          isArchived: widget.idea?.isArchived ?? 0,
          deadline: _deadline?.millisecondsSinceEpoch,
          createdAt: widget.idea?.createdAt ?? _createdAt ?? n,
          updatedAt: n,
        ));
      }

      if (_reminder != null && _reminder!.isAfter(DateTime.now())) {
        await NotificationService.scheduleNotification(
          ideaId + 1000, '💡 ${_titleCtrl.text.trim()}',
          'এই আইডিয়ার কাজ করার সময় হয়েছে!', _reminder!,
        );
      }

      if (_attachments.isNotEmpty) {
        for (final a in _attachments) {
          await DBHelper.insertFile(IdeaFile(
            ideaId: ideaId, projectId: widget.project.id!,
            name: a.name, type: a.type,
            content: a.content, createdAt: n, updatedAt: n,
          ));
        }
        _attachments.clear();
        if (mounted) setState(() {});
      }
      if (mounted) setState(() => _saveState = '✓ সেভ হয়েছে');
      _changed = true;
    } finally {
      _persisting = false;
    }
  }

  Future<void> _saveAndClose() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('শিরোনামটা লিখুন')));
      return;
    }
    _savedExplicitly = true;
    _debounce?.cancel();
    await _persist();
    await _persist(); // চলমান সেভের পরে লেখা বদলে থাকলে সর্বশেষটাও সেভ
    if (mounted) Navigator.pop(context, true);
  }

  // ── Attachments ────────────────────────────────────────────
  Future<void> _pickImage(ImageSource source) async {
    final picked = await BubblePicker.pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final b64 = base64Encode(bytes);
    final ext = picked.name.split('.').last.toLowerCase();
    final name = picked.name.toLowerCase().contains('icon')
        ? picked.name : 'image_${_attachments.length + 1}.$ext';
    setState(() => _attachments.add(_Attachment(name: name, type: 'image', content: b64)));
  }

  Future<void> _pickFile() async {
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
      setState(() => _attachments.add(_Attachment(
          name: pf.name, type: isText ? 'text' : 'binary', content: content)));
    }
  }

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;
    final dir = await getTemporaryDirectory();
    _recordPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: _recordPath!);
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path != null) {
      final bytes = await File(path).readAsBytes();
      final b64 = base64Encode(bytes);
      final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      setState(() => _attachments.add(_Attachment(name: name, type: 'audio', content: b64)));
    }
  }

  Future<void> _removeExistingFile(IdeaFile f) async {
    if (f.id == null) return;
    await DBHelper.deleteFile(f.id!);
    setState(() => _existingFiles.removeWhere((e) => e.id == f.id));
  }

  Future<void> _pickDeadline() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _deadline ?? DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (d != null) setState(() => _deadline = d);
  }

  Future<void> _pickReminder() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (t == null) return;
    setState(() => _reminder = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  String _dateLabel(DateTime d) => '${d.day}/${d.month}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.idea != null;
    return Scaffold(
      backgroundColor: AppTheme.page,
      appBar: AppBar(
        backgroundColor: AppTheme.page,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            // সেভ হওয়ার আগেই ✕ চাপলে আগে লিখে নাও, তারপর বেরোও —
            // যাতে তালিকায় ফিরে নতুন/বদলানো লেখাটা দেখা যায়।
            await _persist();
            if (mounted) Navigator.pop(context, _changed);
          },
        ),
        title: Text(_saveState,
            style: TextStyle(
                color: _saveState == '✓ সেভ হয়েছে' ? AppTheme.green : AppTheme.textMuted,
                fontSize: 13, fontWeight: FontWeight.w600)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _saveAndClose,
              style: TextButton.styleFrom(
                backgroundColor: AppTheme.textPrimary,
                foregroundColor: AppTheme.page,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              child: Text(isEdit ? 'আপডেট' : 'সেভ করুন',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _titleCtrl,
            autofocus: !isEdit,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: 26, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              hintText: 'শিরোনাম',
              hintStyle: TextStyle(color: AppTheme.textMuted, fontWeight: FontWeight.w800),
              border: InputBorder.none,
            ),
          ),
          TextField(
            controller: _bodyCtrl,
            maxLines: null,
            minLines: 8,
            keyboardType: TextInputType.multiline,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, height: 1.9),
            decoration: InputDecoration(
              hintText: 'লিখুন…',
              hintStyle: TextStyle(color: AppTheme.textMuted),
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: 8),

          // ── Attached images (real thumbnails, inline) ──────
          ..._attachments.where((a) => a.type == 'image').toList().asMap().entries.map((e) {
            final i = e.key; final a = e.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(base64Decode(a.content),
                      width: double.infinity, height: 170, fit: BoxFit.cover),
                ),
                Positioned(
                  top: 8, right: 8,
                  child: GestureDetector(
                    onTap: () => setState(() => _attachments.removeAt(
                        _attachments.indexWhere((x) => x.content == a.content && x.type == 'image'))),
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                      child: const Icon(Icons.close, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ]),
            );
          }),
          // ── Attached files / audio ─────────────────────────
          ..._attachments.where((a) => a.type != 'image').toList().map((a) {
            final icon = a.type == 'audio' ? Icons.mic : Icons.insert_drive_file_outlined;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border)),
              child: Row(children: [
                Icon(icon, color: AppTheme.textSecondary, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(a.name,
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
                GestureDetector(
                  onTap: () => setState(() => _attachments.remove(a)),
                  child: Icon(Icons.close, color: AppTheme.textMuted, size: 18),
                ),
              ]),
            );
          }),
          // ── Already-saved files (edit mode) ────────────────
          if (_existingFiles.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text('আগের ফাইল (${_existingFiles.length})',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            ..._existingFiles.map((f) {
              final isImg = f.isImage;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border)),
                child: Row(children: [
                  Icon(isImg ? Icons.image_outlined : Icons.insert_drive_file_outlined,
                      color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(f.name,
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                      overflow: TextOverflow.ellipsis)),
                  GestureDetector(
                    onTap: () => _removeExistingFile(f),
                    child: Icon(Icons.close, color: AppTheme.textMuted, size: 18),
                  ),
                ]),
              );
            }),
          ],
          if (_loadingFiles)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),

          // ── Attach row ─────────────────────────────────────
          Row(children: [
            _attachBtn(Icons.photo_library_outlined, 'ছবি', AppTheme.green,
                () => _pickImage(ImageSource.gallery)),
            const SizedBox(width: 8),
            _attachBtn(Icons.camera_alt_outlined, 'ক্যামেরা', AppTheme.yellow,
                () => _pickImage(ImageSource.camera)),
            const SizedBox(width: 8),
            _attachBtn(Icons.attach_file_outlined, 'ফাইল', AppTheme.accent, _pickFile),
            const SizedBox(width: 8),
            Expanded(child: GestureDetector(
              onTap: () => _isRecording ? _stopRecording() : _startRecording(),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _isRecording ? AppTheme.red.withOpacity(0.12) : AppTheme.card,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: _isRecording ? AppTheme.red : AppTheme.border, width: _isRecording ? 2 : 1),
                ),
                child: Column(children: [
                  Icon(_isRecording ? Icons.stop_circle : Icons.mic_outlined,
                      color: _isRecording ? AppTheme.red : AppTheme.textMuted, size: 20),
                  const SizedBox(height: 3),
                  Text(_isRecording ? 'Stop' : 'ভয়েস',
                      style: TextStyle(
                          color: _isRecording ? AppTheme.red : AppTheme.textMuted,
                          fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              ),
            )),
          ]),
          const SizedBox(height: 20),

          // ── Status ─────────────────────────────────────────
          _segLabel('অবস্থা'),
          _segmented(['todo', 'doing', 'done'], _status, (v) {
            setState(() => _status = v);
            _scheduleAutosave();
          }),
          const SizedBox(height: 16),

          // ── Priority ───────────────────────────────────────
          _segLabel('গুরুত্ব'),
          _segmented(['low', 'medium', 'high'], _priority, (v) {
            setState(() => _priority = v);
            _scheduleAutosave();
          }),
          const SizedBox(height: 16),

          // ── Deadline ───────────────────────────────────────
          _segLabel('শেষ তারিখ (ঐচ্ছিক)'),
          _dateRow(
            icon: Icons.event_outlined,
            label: _deadline != null ? _dateLabel(_deadline!) : 'তারিখ বেছে নিন',
            hasValue: _deadline != null,
            onTap: _pickDeadline,
            onClear: () { setState(() => _deadline = null); _scheduleAutosave(); },
          ),
          const SizedBox(height: 16),

          // ── Reminder ───────────────────────────────────────
          _segLabel('রিমাইন্ডার (ঐচ্ছিক)'),
          _dateRow(
            icon: Icons.alarm,
            label: _reminder != null
                ? '${_dateLabel(_reminder!)} ${_reminder!.hour}:${_reminder!.minute.toString().padLeft(2, '0')}'
                : 'তারিখ ও সময় বেছে নিন',
            hasValue: _reminder != null,
            onTap: _pickReminder,
            onClear: () => setState(() => _reminder = null),
          ),
        ]),
      ),
    );
  }

  Widget _segLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: TextStyle(
        color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
  );

  Widget _segmented(List<String> values, String current, ValueChanged<String> onPick) {
    return Row(children: values.map((v) {
      final sel = current == v;
      final label = v == 'todo' ? 'বাকি'
          : v == 'doing' ? 'চলছে'
          : v == 'done' ? 'শেষ'
          : v == 'low' ? 'কম'
          : v == 'medium' ? 'মাঝারি' : 'জরুরি';
      return Expanded(child: Padding(
        padding: EdgeInsets.only(right: v == values.last ? 0 : 8),
        child: GestureDetector(
          onTap: () => onPick(v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? AppTheme.textPrimary : AppTheme.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: sel ? AppTheme.textPrimary : AppTheme.border),
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: sel ? AppTheme.page : AppTheme.textSecondary,
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ),
      ));
    }).toList());
  }

  Widget _dateRow({required IconData icon, required String label,
      required bool hasValue, required VoidCallback onTap,
      required VoidCallback onClear}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Icon(icon, color: hasValue ? AppTheme.textPrimary : AppTheme.textMuted, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label,
              style: TextStyle(
                  color: hasValue ? AppTheme.textPrimary : AppTheme.textMuted,
                  fontSize: 13))),
          if (hasValue)
            GestureDetector(
              onTap: onClear,
              child: Icon(Icons.close, color: AppTheme.textMuted, size: 16),
            ),
        ]),
      ),
    );
  }

  Widget _attachBtn(IconData icon, String label, Color color, VoidCallback onTap) =>
      Expanded(child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
          ]),
        ),
      ));
}

class _Attachment {
  final String name, type, content;
  _Attachment({required this.name, required this.type, required this.content});
}
