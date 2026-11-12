import 'dart:async';
import 'package:flutter/material.dart';
import '../db/db_helper.dart';
import '../models/project.dart';
import '../widgets/app_theme.dart';

class ProjectFormScreen extends StatefulWidget {
  final Project? project;
  const ProjectFormScreen({super.key, this.project});
  @override State<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _ProjectFormScreenState extends State<ProjectFormScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  // Default color — not user-selectable in new project form
  int _colorValue = AppTheme.projectColors[0].value;
  bool _saving = false;
  bool _savedExplicitly = false;
  bool _persisting = false; // একই সময়ে দুটো _persist চললে নতুন প্রজেক্ট ডুপ্লিকেট হতো
  int? _createdProjectId;
  Project? _createdProject; // autosave-এ নতুন বানানো প্রজেক্ট (এডিটে copyWith-এর ভিত্তি)
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.project != null) {
      final p = widget.project!;
      _name.text = p.name;
      _desc.text = p.description ?? '';
      _colorValue = p.colorValue;
    }
    // Periodic autosave while typing — protects against the app itself
    // being killed/backgrounded mid-edit, not just navigating away.
    _name.addListener(_scheduleAutosave);
    _desc.addListener(_scheduleAutosave);
  }

  void _scheduleAutosave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), _persist);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Autosave-on-close: if the screen is being torn down any way other
    // than the explicit Save button — back gesture, back button, the app
    // getting backgrounded/killed while this screen is up — don't lose
    // whatever was typed. This can't be `await`ed from dispose(), so it
    // fires and forgets; that's fine since _persist() guards against
    // being called with an empty name.
    if (!_savedExplicitly) _persist();
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  /// Writes the current form fields to the database. For a brand-new
  /// project, remembers the created id so a later autosave (e.g. from
  /// dispose) updates that same row instead of inserting a duplicate.
  /// এডিটে শুধু নাম/বিবরণ/রঙ বদলায় — লক, ট্যাগ, স্ট্যাটাস, ভার্সন,
  /// সর্ট অর্ডার আগেরটাই থাকে (নতুন Project বানিয়ে লিখলে লক খুলে যেত,
  /// ভার্সন 1-এ নামত, ট্যাগ মুছে যেত)।
  Future<void> _persist() async {
    if (_persisting) return;
    if (_name.text.trim().isEmpty) return;
    _persisting = true;
    try {
      await _persistInner();
    } finally {
      _persisting = false;
    }
  }

  Future<void> _persistInner() async {
    final n = now();
    final existingId = widget.project?.id ?? _createdProjectId;
    if (existingId == null) {
      final p = Project(
        name: _name.text.trim(),
        description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        colorValue: _colorValue, createdAt: n, updatedAt: n,
      );
      _createdProjectId = await DBHelper.insertProject(p);
      _createdProject = p.copyWith(id: _createdProjectId);
    } else {
      final base = widget.project ?? _createdProject;
      await DBHelper.updateProject(Project(
        id: existingId,
        name: _name.text.trim(),
        description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        colorValue: _colorValue,
        tags: base?.tags ?? const [],
        status: base?.status ?? 'active',
        version: base?.version ?? 1,
        sortOrder: base?.sortOrder ?? 0,
        locked: base?.locked ?? 0,
        createdAt: base?.createdAt ?? n,
        updatedAt: n,
      ));
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('প্রজেক্টের নাম দাও!')));
      return;
    }
    setState(() => _saving = true);
    // dispose()-এর autosave যেন আরেকটা _persist না ডাকে (ডুপ্লিকেট রেস) —
    // তাই await-এর আগেই পতাকা বসাও।
    _savedExplicitly = true;
    await _persist();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.project != null;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(isEdit ? 'প্রজেক্ট এডিট' : 'নতুন প্রজেক্ট'),
        // Save/Update lives here at the top — always visible, never hidden
        // by the keyboard the way a bottom button would be.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
                  : const Icon(Icons.check, size: 18, color: AppTheme.accent),
              label: Text(isEdit ? 'আপডেট' : 'সেভ',
                  style: const TextStyle(color: AppTheme.accent,
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label('প্রজেক্টের নাম *'),
          _field(_name, 'যেমন: Weather App, Portfolio Site'),
          const SizedBox(height: 16),
          _label('বিবরণ (ঐচ্ছিক)'),
          _field(_desc, 'প্রজেক্ট সম্পর্কে কিছু লিখো...', maxLines: 3),
        ]),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style:  TextStyle(
        color: AppTheme.textSecondary, fontSize: 13,
        fontWeight: FontWeight.w600)),
  );

  Widget _field(TextEditingController ctrl, String hint,
      {int maxLines = 1}) => TextField(
    controller: ctrl, maxLines: maxLines,
    style:  TextStyle(color: AppTheme.textPrimary, fontSize: 15),
    decoration: InputDecoration(
      hintText: hint, hintStyle:  TextStyle(color: AppTheme.textMuted),
      filled: true, fillColor: AppTheme.bg3,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:  BorderSide(color: AppTheme.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:  BorderSide(color: AppTheme.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
  );
}
