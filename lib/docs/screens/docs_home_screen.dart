import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../family/screens/family_ui.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../services/auth_service.dart';
import '../../services/secure_screen.dart';
import '../../widgets/app_theme.dart';
import '../models/doc_models.dart';
import '../services/doc_owners.dart';
import '../services/docs_service.dart';
import 'doc_form_sheet.dart';
import 'doc_viewer_screen.dart';
import '../services/docs_export_service.dart';
import 'docs_backup_sheet.dart';
import 'doc_type_picker.dart';

/// ডকুমেন্ট ও সনদের এনক্রিপ্টেড ভল্ট। ঢুকতে ফিঙ্গারপ্রিন্ট/PIN লাগে; অ্যাপ
/// ব্যাকগ্রাউন্ডে গেলে নিজে বন্ধ হয় (ভল্টের মতো)।
class DocsHomeScreen extends StatefulWidget {
  /// ক্যামেরা/ফাইল পিকার/শেয়ারের মতো বাইরের স্ক্রিন খোলার সময় true — তখন অটো-লক চলে না।
  static bool suppressAutoLock = false;
  const DocsHomeScreen({super.key});
  @override State<DocsHomeScreen> createState() => _DocsHomeScreenState();
}

class _DocsHomeScreenState extends State<DocsHomeScreen> with WidgetsBindingObserver {
  bool _authed = false;
  bool _authFailed = false;
  bool _loading = true;
  List<VaultDoc> _docs = [];
  int _tray = 0; // আপলোডের জন্য প্রস্তুত ফাইলের সংখ্যা
  String _cat = 'all';
  String? _owner; // null = এখনো বাছা হয়নি (প্রথমবার); DocOwners.all = সবার; নইলে একজনের নাম
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SecureScreen.on(); // ডকস খোলা থাকলে স্ক্রিনশট/থাম্বনেইল বন্ধ
    DocsService.changes.addListener(_load);
    DocsExport.trayChanges.addListener(_loadTray);
    _owner = DocOwners.selected();
    _auth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SecureScreen.off();
    DocsService.changes.removeListener(_load);
    DocsExport.trayChanges.removeListener(_loadTray);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && mounted && !DocsHomeScreen.suppressAutoLock) {
      // উপরে ভিউয়ার/শিট খোলা থাকলেও সব বন্ধ হয়ে হোমে ফেরে।
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _auth() async {
    setState(() { _authFailed = false; });
    final ok = await AuthService.authenticate(reason: 'ডকুমেন্ট ভল্ট খুলতে যাচাই করো');
    if (!ok) {
      if (mounted) setState(() => _authFailed = true);
      return;
    }
    _authed = true;
    // আগের সেশনের সাময়িক ডিক্রিপ্টেড ফাইল (থাকলে) সাফ।
    try {
      final dir = await getTemporaryDirectory();
      for (final e in dir.listSync()) {
        if (e is File && e.uri.pathSegments.last.startsWith('docs_tmp_')) e.deleteSync();
      }
    } catch (_) {}
    // আগের শেয়ারের সাময়িক কপি সাফ; মেয়াদ-শেষ আপলোড-ট্রের ফাইলও।
    await DocsExport.cleanShareTemp();
    await _load();
  }

  Future<void> _loadTray() async {
    if (!_authed) return;
    final n = await DocsExport.trayCount();
    if (mounted) setState(() => _tray = n);
  }

  Future<void> _load() async {
    if (!_authed) return;
    final l = await DocsService.list();
    if (mounted) setState(() { _docs = l; _loading = false; });
    _loadTray();
  }

  Color _expColor(int d) => d < 0 ? AppTheme.red : (d <= 30 ? AppTheme.yellow : AppTheme.textSecondary);

  Future<void> _setOwner(String v) async {
    await DocOwners.select(v);
    if (mounted) setState(() => _owner = v);
  }

  Future<void> _addOwner() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('নতুন নাম'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'যার ডকুমেন্ট তার নাম'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('যোগ করো', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    await DocOwners.add(name);
    await _setOwner(name);
  }

  /// বাছা নামটা বদলায় — ওই নামের সব ডকুমেন্টও নতুন নামে চলে যায় (ফাইল/নম্বর/রিমাইন্ডার যেমন ছিল তেমন)।
  Future<void> _renameOwner() async {
    final old = _owner;
    if (old == null || old == DocOwners.all) return;
    final ctrl = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('নাম বদলাও'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'নতুন নাম', helperText: 'এই নামের সব ডকুমেন্ট নতুন নামে চলে যাবে'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('বদলাও', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == old) return;
    final n = await DocsService.renameOwner(old, name);
    final finalName = await DocOwners.rename(old, name);
    if (!mounted) return;
    setState(() => _owner = finalName);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n > 0 ? '"$old" → "$finalName": ${bn(n)}টা ডকুমেন্টের নাম বদলেছে' : 'নাম বদলেছে'),
    ));
  }

  /// তালিকা থেকে নাম সরায় — শুধু যার কোনো ডকুমেন্ট নেই। ডকুমেন্ট থাকলে আগে সেগুলো অন্য নামে নিতে হবে (মোছা হয় না)।
  Future<void> _removeOwner() async {
    final name = _owner;
    if (name == null || name == DocOwners.all) return;
    final count = _docs.where((d) => DocOwners.keyOf(d) == name).length;
    if (count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('"$name"-এর ${bn(count)}টা ডকুমেন্ট আছে — সরানো যাবে না। আগে "নামটা বদলাও" দিয়ে অন্য নামে মেলাও বা ডকুমেন্টগুলো সরাও।'),
      ));
      return;
    }
    final ok = await DocOwners.remove(name);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('অন্তত একটা নাম রাখতে হবে')));
      }
      return;
    }
    final sel = DocOwners.selected();
    if (mounted) setState(() => _owner = sel);
  }

  Future<void> _add() async {
    final t = await showDocTypePicker(context);
    if (t == null || !mounted) return;
    final preset = (_owner == null || _owner == DocOwners.all) ? null : _owner;
    final saved = await showDocForm(context, template: t, presetCategory: _cat == 'all' ? null : _cat, presetOwner: preset);
    if (!saved || !mounted) return;
    // অন্য নামে যোগ করে থাকলে সেই নামের তালিকায় চলে যাই — যাতে নতুন ডকুমেন্টটা চোখে পড়ে।
    final l = await DocsService.list();
    if (l.isEmpty) return;
    l.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final who = DocOwners.keyOf(l.first);
    if (_owner != DocOwners.all && _owner != who) await _setOwner(who);
  }

  /// অ্যাপ বারের শিরোনাম: এখন কার ডকুমেন্ট দেখাচ্ছে (ড্রপডাউন) — নাম বদলাতে ট্যাপ করো।
  Widget _ownerTitle() {
    final name = _owner == DocOwners.all ? 'সবার ডকুমেন্ট' : (_owner ?? '');
    final names = DocOwners.withDocs(_docs);
    return PopupMenuButton<String>(
      tooltip: 'কার ডকুমেন্ট?',
      color: AppTheme.bg2,
      offset: const Offset(0, 44),
      onSelected: (v) {
        if (v == '__add__') {
          _addOwner();
        } else if (v == '__rename__') {
          _renameOwner();
        } else if (v == '__remove__') {
          _removeOwner();
        } else {
          _setOwner(v);
        }
      },
      itemBuilder: (_) => [
        for (final n in names)
          PopupMenuItem<String>(
            value: n,
            child: Row(children: [
              Icon(_owner == n ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18, color: _owner == n ? AppTheme.accent : AppTheme.textMuted),
              const SizedBox(width: 10),
              Expanded(child: Text(n, style: TextStyle(fontWeight: _owner == n ? FontWeight.w800 : FontWeight.w500))),
              Text(bn(_docs.where((d) => DocOwners.keyOf(d) == n).length),
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ]),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(value: DocOwners.all, child: const Text('👥 সবার ডকুমেন্ট')),
        const PopupMenuItem<String>(value: '__add__', child: Text('➕ নতুন নাম যোগ করো')),
        if (_owner != DocOwners.all) ...[
          PopupMenuItem<String>(value: '__rename__', child: Text('✏️ "$_owner" নামটা বদলাও')),
          PopupMenuItem<String>(value: '__remove__', child: Text('🗑️ "$_owner" নামটা সরাও')),
        ],
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('👤 '),
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }

  /// প্রথমবার ঢুকলে: কার ডকুমেন্ট দেখবে বাছো (না থাকলে নতুন নাম যোগ করো)।
  Widget _firstPicker() {
    final names = DocOwners.withDocs(_docs);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 40), children: [
      Text('কার ডকুমেন্ট দেখবে?',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Text('নামটা বাছো — শুধু তার ডকুমেন্টই দেখাবে। পরে ওপরের নামে ট্যাপ করে বদলানো যাবে।',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4)),
      const SizedBox(height: 14),
      for (final n in names)
        fCard(
          onTap: () => _setOwner(n),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.13), borderRadius: BorderRadius.circular(14)),
              child: const Text('👤', style: TextStyle(fontSize: 20)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(n, style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Text('${bn(_docs.where((d) => DocOwners.keyOf(d) == n).length)}টা',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, color: AppTheme.textMuted),
          ]),
        ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: _addOwner,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('তালিকায় নেই? নতুন নাম যোগ করো'),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: (_authed && _owner != null) ? _ownerTitle() : const Text('ডকুমেন্ট ও সনদ'),
        actions: [
          if (_authed)
            IconButton(
              icon: const Icon(Icons.enhanced_encryption_outlined),
              tooltip: 'ব্যাকআপ / রিস্টোর',
              onPressed: () => showDocsBackupSheet(context),
            ),
        ],
      ),
      floatingActionButton: (_authed && _owner != null)
          ? FloatingActionButton(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
              onPressed: _add,
              child: const Icon(Icons.add),
            )
          : null,
      body: !_authed ? _lockedBody() : (_loading ? const Center(child: CircularProgressIndicator(color: AppTheme.accent)) : _body()),
    );
  }

  Widget _lockedBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline_rounded, size: 46, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          Text(_authFailed ? 'যাচাই সম্পন্ন হয়নি' : 'যাচাই করা হচ্ছে...',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
          if (_authFailed) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
              onPressed: _auth,
              icon: const Icon(Icons.fingerprint),
              label: const Text('আবার চেষ্টা করো'),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _body() {
    if (_owner == null) return _firstPicker();
    // বাছা নামের ডকুমেন্টই (বা "সবার") — বাকি সব হিসাব (মেয়াদ, ক্যাটাগরি, সংখ্যা) এর ভেতর থেকেই
    final scoped = _owner == DocOwners.all ? _docs : _docs.where((d) => DocOwners.keyOf(d) == _owner).toList();
    final q = _search.text.trim().toLowerCase();
    final list = scoped.where((d) {
      if (_cat != 'all' && d.category != _cat) return false;
      if (q.isNotEmpty &&
          !d.title.toLowerCase().contains(q) &&
          !d.note.toLowerCase().contains(q) &&
          !d.ownerLabel.toLowerCase().contains(q)) return false;
      return true;
    }).toList();

    final expiring = scoped.where((d) => d.daysToExpiry != null && d.daysToExpiry! <= 30).length;
    final cats = docCategories.keys.where((k) => scoped.any((d) => d.category == k)).toList();

    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 90), children: [
      fCard(
        child: Row(children: [
          Icon(Icons.shield_rounded, color: AppTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text('ফাইল AES-256 এনক্রিপ্টেড, ফোনের বাইরে যায় না। ফোন হারানোর ঝুঁকি এড়াতে ⋮-এর পাশের 🔐 থেকে পাসওয়ার্ড-সুরক্ষিত ব্যাকআপ নাও।',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.4)),
          ),
        ]),
      ),
      if (_tray > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.upload_file_rounded, color: AppTheme.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${bn(_tray)}টা ফাইল ব্রাউজার/সাইটে আপলোডের জন্য প্রস্তুত (ফাইল-পিকারে "ডকুমেন্ট ভল্ট")। ১০ মিনিট পর নিজে মুছবে।',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
            ),
            TextButton(
              onPressed: () async {
                await DocsExport.clearTray();
                _loadTray();
              },
              child: Text('বন্ধ করো', style: TextStyle(color: AppTheme.red, fontSize: 12.5)),
            ),
          ]),
        ),
      if (expiring > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppTheme.yellow.withOpacity(0.13), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.event_busy_outlined, color: AppTheme.yellow, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${bn(expiring)}টা ডকুমেন্টের মেয়াদ ৩০ দিনের মধ্যে শেষ হচ্ছে বা শেষ হয়ে গেছে',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
            ),
          ]),
        ),
      if (scoped.length > 6)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'খোঁজো',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
              filled: true,
              fillColor: AppTheme.bg2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
        ),
      if (cats.length > 1)
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            _chip('all', 'সব ${bn(scoped.length)}'),
            for (final k in cats)
              _chip(k, '${docCategories[k]!.$1} ${docCategories[k]!.$2} ${bn(scoped.where((d) => d.category == k).length)}'),
          ]),
        ),
      if (scoped.isEmpty)
        fEmpty(Icons.folder_special_outlined,
            '${_owner == DocOwners.all ? '' : '$_owner-এর '}কোনো ডকুমেন্ট নেই।\nনিচের + বাটনে ট্যাপ করে NID, জন্মনিবন্ধন, SSC/HSC সনদ, ছবি, স্বাক্ষর বা PDF যোগ করো।')
      else if (list.isEmpty)
        fEmpty(Icons.search_off_rounded, 'কিছু পাওয়া যায়নি')
      else
        for (final d in list) _docCard(d),
    ]);
  }

  Widget _chip(String key, String label) {
    final sel = _cat == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(color: sel ? Colors.white : AppTheme.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w600)),
        selected: sel,
        showCheckmark: false,
        selectedColor: AppTheme.accent,
        backgroundColor: AppTheme.bg2,
        side: BorderSide(color: sel ? AppTheme.accent : AppTheme.border),
        onSelected: (_) => setState(() => _cat = key),
      ),
    );
  }

  Widget _docCard(VaultDoc d) {
    final days = d.daysToExpiry;
    final cat = docCategories[d.category] ?? docCategories['other']!;
    return fCard(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DocViewerScreen(doc: d)));
        _load();
      },
      child: Row(children: [
        Container(
          width: 46, height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: AppTheme.accent.withOpacity(0.13), borderRadius: BorderRadius.circular(14)),
          child: Text(cat.$1, style: const TextStyle(fontSize: 22)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('${_owner == DocOwners.all ? '👤 ${DocOwners.keyOf(d)} · ' : ''}${cat.$2} · ${d.pages.isEmpty ? 'ফাইল নেই' : '${bn(d.pages.length)}টা পাতা'}${d.numberEnc.isNotEmpty ? ' · 🔢 নম্বর আছে' : ''}',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ]),
        ),
        if (days != null)
          fChip(days < 0 ? 'মেয়াদ শেষ' : (days <= 90 ? '${bn(days)} দিন' : '✓ মেয়াদ আছে'), _expColor(days)),
      ]),
    );
  }
}
