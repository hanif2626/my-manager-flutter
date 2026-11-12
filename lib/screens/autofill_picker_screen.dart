import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_autofill_service/flutter_autofill_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vault_entry.dart';
import '../services/secure_screen.dart';
import '../services/vault_service.dart';
import '../services/auth_service.dart';
import '../widgets/app_theme.dart';

enum _Mode { loading, authFailed, pick, save, noMatch }

/// autofillEntryPoint()-এর রুট উইজেট। অন্য অ্যাপে লগইন ফর্মে ট্যাপ করলে
/// (পাসওয়ার্ড বাছাই) অথবা নতুন লগইন সাবমিট করলে (সেভ সাজেশন) Android
/// এই স্ক্রিন খোলে। উইন্ডো স্বচ্ছ — নিচ থেকে উঠে আসা একটা কার্ড (bottom
/// sheet) দেখায়, বাইরে ট্যাপ করলে বন্ধ হয়।
///
/// স্মার্ট আচরণ:
///  • একটাই মিল থাকলে কোনো ট্যাপ ছাড়াই ফিল
///  • ২ মিনিটের মধ্যে আবার যাচাই চায় না
///  • এই সাইটে শেষবার ব্যবহৃত একাউন্ট সবার উপরে
///  • সেভের সময় একই লগইন আগে থেকে থাকলে চুপচাপ বন্ধ, পাসওয়ার্ড বদলালে "আপডেট"
///  • মিল না থাকলে চুপচাপ বন্ধ নয় — "সব লগইন দেখাও" শিট আসে
///  • হাতে বেছে নেওয়া লগইন ওই সাইটের সাথে মনে থাকে — পরের বার নিজে নিজে মিলে যায়
class AutofillPickerApp extends StatefulWidget {
  const AutofillPickerApp({super.key});
  @override State<AutofillPickerApp> createState() => _AutofillPickerAppState();
}

class _AutofillPickerAppState extends State<AutofillPickerApp> {
  _Mode _mode = _Mode.loading;
  List<VaultEntry> _matches = [];
  List<VaultEntry> _all = [];
  bool _showAll = false;
  SaveInfoMetadata? _saveInfo;
  String? _saveSiteLabel;
  VaultEntry? _existing;
  bool _revealPw = false;
  bool _saving = false;
  String _siteKey = '';
  String? _lastUsedId;
  // এই সাইটে আগে হাতে বেছে নেওয়া এন্ট্রির id-গুলো (শেখা সংযোগ)।
  Set<String> _assocIds = {};
  String _cat = 'login';

  // অটোফিলে যেসব ক্যাটাগরি দেখানো হবে (ক্রমও এটাই)। কার্ড বাদ — কার্ডের নম্বর
  // পাসওয়ার্ড ফিল্ডে বসানোর মানে হয় না।
  static const _catLabels = {
    'login': 'পাসওয়ার্ড', 'token': 'টোকেন/API', 'note': 'নোট', 'wifi': 'WiFi',
  };
  static const _catIcons = {
    'login': Icons.lock_outline_rounded, 'token': Icons.key_rounded,
    'note': Icons.sticky_note_2_outlined, 'wifi': Icons.wifi_rounded,
  };

  // যাচাইয়ের পর এই সময়ের মধ্যে আবার ফিঙ্গারপ্রিন্ট/PIN চাইবে না।
  static const _authGraceSeconds = 120;
  static const _lastAuthKey = 'af_last_auth_ms';
  /// true (ডিফল্ট) = শুধু যে সাইট/অ্যাপের পাসওয়ার্ড সেভ করা আছে সেখানেই সাজেশন।
  static const onlySavedKey = 'af_only_saved';

  final _titleCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  static const _avatarColors = [
    Color(0xFF6C63FF), Color(0xFF00A6A6), Color(0xFFE85D75), Color(0xFFF29E4C),
    Color(0xFF3FA34D), Color(0xFF3A86FF), Color(0xFFB5179E), Color(0xFF8D6E63),
  ];

  @override
  void initState() {
    super.initState();
    SecureScreen.on(); // পিকারে লগইন তালিকা — স্ক্রিনশট আটকাও
    _init();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _usernameCtrl.dispose();
    _searchCtrl.dispose();
    SecureScreen.off();
    super.dispose();
  }

  /// এই State-এর context MaterialApp-এর উপরে, তাই Navigator.of(context)
  /// এখানে কাজ করে না — Activity বন্ধ করতে সরাসরি SystemNavigator।
  void _finish() => SystemNavigator.pop();

  // ───────────────────────── লজিক ─────────────────────────

  Future<void> _init() async {
    setState(() => _mode = _Mode.loading);

    AutofillMetadata? metadata;
    try {
      metadata = await AutofillService().autofillMetadata;
    } catch (_) {}

    // সেভ ফ্লো-তে ভল্টের কিছু দেখানো হয় না, শুধু নতুন এন্ট্রি যোগ হয় —
    // তাই যাচাই ছাড়াই সরাসরি।
    if (metadata?.saveInfo != null) {
      await _showSave(metadata!);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // আগে মিল খোঁজো (ফিঙ্গারপ্রিন্ট ছাড়াই — এখানে কোনো পাসওয়ার্ড দেখানো হয় না)।
    // এই সাইট/অ্যাপের জন্য কিছু সেভ করা না থাকলে চুপচাপ বন্ধ: কোনো কার্ড নেই,
    // ফিঙ্গারপ্রিন্ট প্রম্পট নেই — বিরক্ত করবে না। সেটিংসে "শুধু সেভ করা সাইটে"
    // বন্ধ করলে আগের মতো সব পাসওয়ার্ডের তালিকা দেখাবে।
    final onlySaved = prefs.getBool(onlySavedKey) ?? true;
    await _prepare(metadata, prefs);
    final hasMatch = _matches.isNotEmpty;
    if (!hasMatch && _all.isEmpty) {
      _finish();
      return;
    }
    // মিল নেই, কিন্তু ভল্টে লগইন আছে: আগে এখানে চুপচাপ বন্ধ হয়ে যেত আর
    // ব্যবহারকারীকে অ্যাপ খুলে সার্চ করতে হতো। এখন ছোট্ট শিটে জানিয়ে
    // "সব লগইন দেখাও"-এর সুযোগ — এক ট্যাপেই পুরো তালিকা (যাচাইসহ)।
    // এই শিটে কোনো গোপন তথ্য থাকে না, তাই যাচাই ছাড়াই দেখানো নিরাপদ।
    if (!hasMatch && onlySaved) {
      if (mounted) setState(() => _mode = _Mode.noMatch);
      return;
    }

    final ok = await _ensureAuth(prefs);
    if (!ok) {
      if (mounted) setState(() => _mode = _Mode.authFailed);
      return;
    }
    await _fillOrPick();
  }

  Future<bool> _ensureAuth(SharedPreferences prefs) async {
    final last = prefs.getInt(_lastAuthKey) ?? 0;
    final diff = DateTime.now().millisecondsSinceEpoch - last;
    // diff ঋণাত্মক মানে সংরক্ষিত সময় ভবিষ্যতে — ঘড়ি পেছানো হয়েছে;
    // সেক্ষেত্রে grace নয়, আবার যাচাই (নইলে ঘড়ি পিছিয়ে grace
    // অনির্দিষ্ট বাড়ানো যেত)।
    final fresh = diff >= 0 && diff < _authGraceSeconds * 1000;
    if (fresh) return true;
    final ok = await AuthService.authenticate(reason: 'Autofill-এর জন্য যাচাই করো');
    if (ok) {
      await prefs.setInt(_lastAuthKey, DateTime.now().millisecondsSinceEpoch);
    }
    return ok;
  }

  /// "মিল নেই" শিট থেকে: যাচাই করে পুরো লগইন তালিকা খোলো।
  Future<void> _showAllLogins() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ok = await _ensureAuth(prefs);
    if (!ok) {
      if (mounted) setState(() => _mode = _Mode.authFailed);
      return;
    }
    if (mounted) {
      setState(() {
        _showAll = true;
        _mode = _Mode.pick;
      });
    }
  }

  String _registrableDomain(String host) {
    final parts = host.toLowerCase().split('.');
    if (parts.length <= 2) return parts.join('.');
    const twoLevel = {'co', 'com', 'org', 'net', 'gov', 'edu', 'ac'};
    if (twoLevel.contains(parts[parts.length - 2]) && parts.last.length == 2) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return parts.sublist(parts.length - 2).join('.');
  }

  String _hostOf(String url) {
    var u = url.toLowerCase().trim();
    u = u.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    u = u.split('/').first.split('?').first.split(':').first;
    return u;
  }

  /// দেখানোর জন্য সুন্দর নাম: http://, www., শেষের / বাদ।
  String _pretty(String s) {
    var t = s.trim();
    t = t.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
    t = t.replaceFirst(RegExp(r'^www\.'), '');
    if (t.endsWith('/')) t = t.substring(0, t.length - 1);
    return t.isEmpty ? s : t;
  }

  Set<String> _packageTokens(String pkg) {
    const skip = {'com', 'org', 'net', 'android', 'app', 'apps', 'mobile', 'www',
      'google', 'the', 'lite', 'main', 'client', 'release', 'io', 'co'};
    return pkg.toLowerCase().split('.')
        .where((t) => t.length >= 4 && !skip.contains(t)).toSet();
  }

  bool _sameSite(String? url, String? label) {
    if (url == null || label == null || url.isEmpty || label.isEmpty) return false;
    if (url == label) return true;
    if (_registrableDomain(_hostOf(url)) == _registrableDomain(_hostOf(label))) return true;
    // অ্যাপের প্যাকেজ (com.redotpay.app) বনাম ওয়েব ডোমেইন (redotpay.com):
    // মূল নামটা এক হলে একই সাইট ধরো — নইলে সেভের সময় ডুপ্লিকেট এন্ট্রি হয়।
    final la = _registrableDomain(_hostOf(url)).split('.').first;
    final lb = _registrableDomain(_hostOf(label)).split('.').first;
    return la.length >= 4 && la == lb;
  }

  Future<void> _showSave(AutofillMetadata metadata) async {
    final saveInfo = metadata.saveInfo!;
    final domains = metadata.webDomains.map((d) => d.domain).toList();
    final pkgs = metadata.packageNames.toList();
    final label = domains.isNotEmpty ? domains.first : (pkgs.isNotEmpty ? pkgs.first : null);
    final username = saveInfo.username ?? '';
    final password = saveInfo.password ?? '';

    // আগে থেকে একই সাইট + ইউজারনেমে সেভ করা আছে কিনা।
    VaultEntry? existing;
    try {
      final all = await VaultService.getAll();
      for (final e in all) {
        if (e.type == 'login' && _sameSite(e.url, label) && (e.username ?? '') == username) {
          existing = e;
          break;
        }
      }
    } catch (_) {}

    // হুবহু একই লগইন আগেই সেভ করা → বিরক্ত না করে চুপচাপ বন্ধ।
    if (existing != null && existing.secret == password && password.isNotEmpty) {
      try { await AutofillService().onSaveComplete(); } catch (_) {}
      _finish();
      return;
    }

    _titleCtrl.text = existing?.title ?? (label != null ? _pretty(label) : '');
    _usernameCtrl.text = username;
    if (mounted) setState(() {
      _saveInfo = saveInfo;
      _saveSiteLabel = label;
      _existing = existing;
      _mode = _Mode.save;
    });
  }

  Future<void> _prepare(AutofillMetadata? metadata, SharedPreferences prefs) async {
    final everything = await VaultService.getAll();
    final fillable = everything.where((e) => _catLabels.containsKey(e.type)).toList();
    final logins = fillable.where((e) => e.type == 'login').toList();

    final pkgs = metadata?.packageNames ?? const <String>{};
    final domains = metadata?.webDomains.map((d) => d.domain).toList() ?? const <String>[];
    final wantedDomains = domains.map(_registrableDomain).toSet();
    final wantedLabels = wantedDomains.map((d) => d.split('.').first).toSet();
    final pkgTokens = <String>{};
    for (final p in pkgs) { pkgTokens.addAll(_packageTokens(p)); }

    _siteKey = wantedDomains.isNotEmpty ? wantedDomains.first : (pkgs.isNotEmpty ? pkgs.first : '');
    _saveSiteLabel = domains.isNotEmpty ? domains.first : (pkgs.isNotEmpty ? pkgs.first : null);
    _lastUsedId = _siteKey.isEmpty ? null : prefs.getString('af_last_$_siteKey');
    final assocRaw = _siteKey.isEmpty ? null : prefs.getString('af_assoc_$_siteKey');
    _assocIds = (assocRaw == null || assocRaw.isEmpty)
        ? <String>{}
        : assocRaw.split(',').where((x) => x.isNotEmpty).toSet();

    final matches = logins.where((e) {
      final url = (e.url ?? '').toLowerCase();
      final title = e.title.toLowerCase();
      for (final p in pkgs) {
        final needle = p.toLowerCase();
        if (url.contains(needle) || title.contains(needle)) return true;
      }
      for (final t in pkgTokens) {
        if (url.contains(t) || title.contains(t)) return true;
      }
      if (url.isNotEmpty && wantedDomains.isNotEmpty) {
        if (wantedDomains.contains(_registrableDomain(_hostOf(url)))) return true;
      }
      for (final l in wantedLabels) {
        if (l.length >= 4 && title.contains(l)) return true;
      }
      return false;
    }).toList();

    // শেখা সংযোগ: আগে এই সাইটে হাতে বেছে নেওয়া এন্ট্রি — URL/টাইটেলে
    // নিয়মমতো মিল না থাকলেও মিল হিসেবে ধরো (একবার বাছলেই পরের বার আসবে)।
    if (_assocIds.isNotEmpty) {
      final have = matches.map((e) => e.id).toSet();
      for (final e in logins) {
        if (_assocIds.contains(e.id) && !have.contains(e.id)) matches.add(e);
      }
    }

    int rank(VaultEntry e) =>
        e.id == _lastUsedId ? 0 : (_assocIds.contains(e.id) ? 1 : 2);
    int cmp(VaultEntry a, VaultEntry b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : b.updatedAt.compareTo(a.updatedAt);
    }
    matches.sort(cmp);
    fillable.sort(cmp);
    _all = fillable;
    _matches = matches;
    // পাসওয়ার্ড ক্যাটাগরি খালি হলে যেটাতে কিছু আছে সেটা দিয়ে শুরু।
    if (logins.isEmpty) {
      for (final t in _catLabels.keys) {
        if (fillable.any((e) => e.type == t)) { _cat = t; break; }
      }
    }

  }

  Future<void> _fillOrPick() async {
    // মাত্র একটাই মিল → কোনো ট্যাপ ছাড়াই সরাসরি ফিল।
    if (_matches.length == 1) {
      final ok = await _select(_matches.first);
      if (ok) return;
    }
    if (mounted) setState(() => _mode = _Mode.pick);
  }

  Future<bool> _select(VaultEntry e) async {
    try {
      if (_siteKey.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('af_last_$_siteKey', e.id);
        // হাতে বেছে নেওয়া (নিয়মে মেলেনি) লগইন হলে এই সাইটের সাথে সংযোগ
        // মনে রাখো — পরের বার আর খুঁজতে হবে না।
        if (e.type == 'login' && !_matches.any((m) => m.id == e.id)) {
          final ids = <String>[..._assocIds.where((i) => i != e.id), e.id];
          final keep = ids.length > 3 ? ids.sublist(ids.length - 3) : ids;
          await prefs.setString('af_assoc_$_siteKey', keep.join(','));
          _assocIds = keep.toSet();
        }
      }
      await AutofillService().resultWithDatasets([
        PwDataset(label: e.title, username: e.username ?? '', password: e.secret),
      ]);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveNewLogin() async {
    final password = _saveInfo?.password ?? '';
    if (password.isEmpty || _saving) return;
    setState(() => _saving = true);
    final title = _titleCtrl.text.trim().isEmpty ? 'নতুন লগইন' : _titleCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    final n = DateTime.now().millisecondsSinceEpoch;
    try {
      final all = await VaultService.getAll();
      VaultEntry? existing;
      for (final e in all) {
        if (e.type == 'login' && _sameSite(e.url, _saveSiteLabel) && (e.username ?? '') == username) {
          existing = e;
          break;
        }
      }
      if (existing != null) {
        await VaultService.update(existing.copyWith(secret: password, updatedAt: n));
      } else {
        await VaultService.insert(VaultEntry(
          id: 'v_$n',
          type: 'login',
          title: title,
          username: username.isEmpty ? null : username,
          secret: password,
          url: _saveSiteLabel,
          createdAt: n,
          updatedAt: n,
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    try { await AutofillService().onSaveComplete(); } catch (_) {}
    _finish();
  }

  Future<void> _dismissSave() async {
    try { await AutofillService().onSaveComplete(); } catch (_) {}
    _finish();
  }

  void _dismiss() {
    if (_mode == _Mode.save) {
      _dismissSave();
    } else {
      _finish();
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Builder(builder: (ctx) {
          final maxH = MediaQuery.of(ctx).size.height * 0.78;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () {}, // কার্ডের ভেতরে ট্যাপে বন্ধ হবে না
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1.0, end: 0.0),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  builder: (c, v, child) => Transform.translate(
                    offset: Offset(0, v * 80),
                    child: Opacity(opacity: 1 - v, child: child),
                  ),
                  child: _sheet(maxH),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _sheet(double maxH) {
    final Widget body;
    switch (_mode) {
      case _Mode.loading:
        body = _stateBox(
          const SizedBox(width: 26, height: 26,
              child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.accent)),
          'প্রস্তুত হচ্ছে...',
        );
        break;
      case _Mode.authFailed:
        body = _stateBox(
          Icon(Icons.lock_outline_rounded, size: 34, color: AppTheme.textMuted),
          'যাচাই সম্পন্ন হয়নি',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
            onPressed: _init,
            icon: const Icon(Icons.fingerprint, size: 20),
            label: const Text('আবার চেষ্টা করো'),
          ),
        );
        break;
      case _Mode.pick:
        body = _buildPick();
        break;
      case _Mode.save:
        body = _buildSave();
        break;
      case _Mode.noMatch:
        body = _buildNoMatch();
        break;
    }

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: AppTheme.border)),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, -4))],
      ),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 38, height: 4,
              decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2))),
          _header(),
          Flexible(child: body),
        ]),
      ),
    );
  }

  Widget _header() {
    final saving = _mode == _Mode.save;
    final site = _saveSiteLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            gradient: const LinearGradient(
              colors: [AppTheme.accent, Color(0xFF8B7CFF)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(Icons.shield_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(saving ? 'লগইন সংরক্ষণ করবে?' : 'My Manager',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              site != null && site.isNotEmpty
                  ? _pretty(site)
                  : (saving ? 'ভল্টে নিরাপদে রাখো' : 'লগইন বেছে নাও'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5),
            ),
          ]),
        ),
        IconButton(
          icon: Icon(Icons.close_rounded, color: AppTheme.textMuted),
          onPressed: _dismiss,
        ),
      ]),
    );
  }

  Widget _stateBox(Widget icon, String text, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        icon,
        const SizedBox(height: 14),
        Text(text, style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        if (action != null) ...[const SizedBox(height: 16), action],
      ]),
    );
  }

  Color _colorFor(String s) {
    final h = s.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
    return _avatarColors[h % _avatarColors.length];
  }

  Widget _avatar(VaultEntry e) {
    if (e.type != 'login') {
      final c = _colorFor(e.type);
      return Container(
        width: 42, height: 42,
        decoration: BoxDecoration(
            color: c.withOpacity(0.18), borderRadius: BorderRadius.circular(13)),
        child: Icon(_catIcons[e.type] ?? Icons.key_rounded, color: c, size: 22),
      );
    }
    final name = _pretty(e.title);
    final first = name.isEmpty ? '?' : String.fromCharCode(name.runes.first);
    final isLetter = RegExp(r'[A-Za-z\u0980-\u09FF]').hasMatch(first);
    final color = _colorFor(name.toLowerCase());
    return Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(13),
      ),
      alignment: Alignment.center,
      child: isLetter
          ? Text(first.toUpperCase(),
              style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800))
          : Icon(Icons.language_rounded, color: color, size: 22),
    );
  }

  Widget _accountTile(VaultEntry e) {
    final isLast = e.id == _lastUsedId;
    final sub = (e.username != null && e.username!.isNotEmpty)
        ? e.username!
        : (e.type != 'login'
            ? (_catLabels[e.type] ?? '')
            : (e.url != null && e.url!.isNotEmpty ? _pretty(e.url!) : 'ইউজারনেম নেই'));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.bg3,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            final ok = await _select(e);
            if (!ok) _finish();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              _avatar(e),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_pretty(e.title), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textPrimary, fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
                ]),
              ),
              if (isLast)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('শেষবার',
                      style: TextStyle(color: AppTheme.accent, fontSize: 11, fontWeight: FontWeight.w700)),
                )
              else
                Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildNoMatch() {
    final site = _saveSiteLabel;
    return _stateBox(
      Icon(Icons.search_off_rounded, size: 34, color: AppTheme.textMuted),
      site != null && site.isNotEmpty
          ? '${_pretty(site)}-এর জন্য সেভ করা লগইন পাইনি'
          : 'এই সাইটের জন্য সেভ করা লগইন পাইনি',
      action: Column(mainAxisSize: MainAxisSize.min, children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
          onPressed: _showAllLogins,
          icon: const Icon(Icons.list_rounded, size: 20),
          label: const Text('সব লগইন দেখাও'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _finish,
          child: Text('বন্ধ করো', style: TextStyle(color: AppTheme.textMuted)),
        ),
      ]),
    );
  }

  Widget _buildPick() {
    if (_all.isEmpty) {
      return _stateBox(
        Icon(Icons.inbox_outlined, size: 34, color: AppTheme.textMuted),
        'ভল্টে এখনো কোনো লগইন নেই',
      );
    }
    final q = _searchCtrl.text.trim().toLowerCase();
    final inCat = _all.where((e) => e.type == _cat).toList();
    final isLogin = _cat == 'login';
    final base = (isLogin && !_showAll && _matches.isNotEmpty) ? _matches : inCat;
    final list = q.isEmpty
        ? base
        : inCat.where((e) =>
            e.title.toLowerCase().contains(q) ||
            (e.username ?? '').toLowerCase().contains(q) ||
            (e.url ?? '').toLowerCase().contains(q)).toList();
    final hiddenCount = inCat.length - _matches.length;
    final cats = _catLabels.keys
        .where((t) => t == 'login' || _all.any((e) => e.type == t)).toList();

    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (cats.length > 1)
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            children: [
              for (final t in cats)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: Icon(_catIcons[t], size: 16,
                        color: _cat == t ? Colors.white : AppTheme.textMuted),
                    label: Text('${_catLabels[t]} ${_all.where((e) => e.type == t).length}',
                        style: TextStyle(
                            color: _cat == t ? Colors.white : AppTheme.textSecondary,
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                    selected: _cat == t,
                    showCheckmark: false,
                    selectedColor: AppTheme.accent,
                    backgroundColor: AppTheme.bg3,
                    side: BorderSide.none,
                    onSelected: (_) => setState(() {
                      _cat = t;
                      _searchCtrl.clear();
                    }),
                  ),
                ),
            ],
          ),
        ),
      if (inCat.length > 5)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'নাম বা ইউজারনেম লিখে খোঁজো',
              hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13.5),
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted, size: 20),
              isDense: true,
              filled: true,
              fillColor: AppTheme.bg3,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            q.isNotEmpty
                ? '${list.length}টা ফলাফল'
                : (!isLogin
                    ? '${_catLabels[_cat]} (${inCat.length}টা)'
                    : (_matches.isEmpty
                        ? 'এই সাইটের সাথে মিল নেই — সব পাসওয়ার্ড'
                        : (_showAll ? 'সব পাসওয়ার্ড' : 'এই সাইটের জন্য ${_matches.length}টা'))),
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      Flexible(
        child: list.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('কিছু পাওয়া যায়নি', style: TextStyle(color: AppTheme.textMuted)),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                children: list.map(_accountTile).toList(),
              ),
      ),
      if (isLogin && q.isEmpty && !_showAll && _matches.isNotEmpty && hiddenCount > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextButton.icon(
            onPressed: () => setState(() => _showAll = true),
            icon: const Icon(Icons.expand_more_rounded, color: AppTheme.accent, size: 20),
            label: Text('আরো ${hiddenCount}টা দেখাও',
                style: const TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w600)),
          ),
        )
      else
        const SizedBox(height: 8),
    ]);
  }

  (String, Color, double) _strength(String p) {
    if (p.isEmpty) return ('', AppTheme.textMuted, 0.0);
    var score = 0;
    if (p.length >= 8) score++;
    if (p.length >= 12) score++;
    if (p.length >= 16) score++;
    if (RegExp(r'[A-Z]').hasMatch(p)) score++;
    if (RegExp(r'[0-9]').hasMatch(p)) score++;
    if (RegExp(r'[!@#\$%^&*()_\-+=?]').hasMatch(p)) score++;
    if (score <= 2) return ('দুর্বল', AppTheme.red, 0.3);
    if (score <= 4) return ('মাঝারি', AppTheme.yellow, 0.65);
    return ('শক্তিশালী', AppTheme.green, 1.0);
  }

  InputDecoration _fieldDeco(String label, IconData icon) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
        prefixIcon: Icon(icon, color: AppTheme.textMuted, size: 20),
        filled: true,
        fillColor: AppTheme.bg3,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppTheme.accent, width: 1.4)),
      );

  Widget _buildSave() {
    final pw = _saveInfo?.password ?? '';
    final hasPw = pw.isNotEmpty;
    final (sLabel, sColor, sFrac) = _strength(pw);
    final updating = _existing != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (updating)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.yellow.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.sync_rounded, color: AppTheme.yellow, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('এই ইউজারনেম ভল্টে আগে থেকেই আছে — পাসওয়ার্ডটা আপডেট হবে',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
              ),
            ]),
          ),
        TextField(
          controller: _titleCtrl,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: _fieldDeco('নাম', Icons.label_outline_rounded),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _usernameCtrl,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: _fieldDeco('ইউজারনেম / ইমেইল', Icons.person_outline_rounded),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: BoxDecoration(color: AppTheme.bg3, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(Icons.key_rounded, color: AppTheme.textMuted, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('পাসওয়ার্ড', style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5)),
                const SizedBox(height: 2),
                Text(
                  !hasPw
                      ? 'পাওয়া যায়নি'
                      : (_revealPw ? pw : '•' * pw.length.clamp(6, 16)),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasPw ? AppTheme.textPrimary : AppTheme.red,
                    fontSize: 15, letterSpacing: _revealPw ? 0.3 : 1.5,
                  ),
                ),
              ]),
            ),
            if (hasPw)
              IconButton(
                icon: Icon(_revealPw ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20, color: AppTheme.textMuted),
                onPressed: () => setState(() => _revealPw = !_revealPw),
              ),
          ]),
        ),
        if (hasPw) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: sFrac, minHeight: 5,
                  backgroundColor: AppTheme.bg3,
                  valueColor: AlwaysStoppedAnimation<Color>(sColor),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(sLabel, style: TextStyle(color: sColor, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ],
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: AppTheme.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _dismissSave,
              child: Text('এখন না', style: TextStyle(color: AppTheme.textSecondary)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: hasPw && !_saving ? _saveNewLogin : null,
              icon: Icon(updating ? Icons.sync_rounded : Icons.lock_rounded, size: 18),
              label: Text(_saving ? 'সংরক্ষণ হচ্ছে...' : (updating ? 'আপডেট করো' : 'ভল্টে সংরক্ষণ করো')),
            ),
          ),
        ]),
      ]),
    );
  }
}
