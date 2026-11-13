import 'package:flutter/material.dart';
import '../models/vault_entry.dart';
import '../services/vault_service.dart';
import '../services/password_generator.dart';
import '../widgets/app_theme.dart';
import 'qr_scan_screen.dart';

class VaultEntryFormScreen extends StatefulWidget {
  final VaultEntry? entry;
  const VaultEntryFormScreen({super.key, this.entry});
  @override State<VaultEntryFormScreen> createState() => _VaultEntryFormScreenState();
}

class _VaultEntryFormScreenState extends State<VaultEntryFormScreen> {
  late String _type;
  final _title = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  final _totpSecret = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  final _labels = const {
    'login': ('লগইন', Icons.lock_outline),
    'note': ('সিকিওর নোট', Icons.sticky_note_2_outlined),
    'card': ('কার্ড', Icons.credit_card),
    'token': ('টোকেন/API Key', Icons.key_outlined),
    'wifi': ('WiFi', Icons.wifi),
  };

  bool get _isEdit => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _type = e?.type ?? 'login';
    if (e != null) {
      _title.text = e.title;
      _username.text = e.username ?? '';
      _secret.text = e.secret;
      _url.text = e.url ?? '';
      _notes.text = e.notes ?? '';
      _totpSecret.text = e.totpSecret ?? '';
    }
  }

  @override
  void dispose() {
    _title.dispose(); _username.dispose(); _secret.dispose();
    _url.dispose(); _notes.dispose(); _totpSecret.dispose();
    super.dispose();
  }

  String get _secretLabel => switch (_type) {
    'note' => 'নোট (বিস্তারিত)',
    'card' => 'কার্ড নম্বর',
    'token' => 'টোকেন / Key',
    'wifi' => 'WiFi পাসওয়ার্ড',
    _ => 'পাসওয়ার্ড',
  };

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('একটা শিরোনাম দাও')));
      return;
    }
    setState(() => _saving = true);
    // otpauth:// লিংক পেস্ট হলে আসল secret-টা বের করো; স্পেস বাদ দাও
    // (Google key স্পেসসহ দেখায়, কিন্তু Base32-তে স্পেসের মানে নেই)।
    var totp = _totpSecret.text.trim();
    if (totp.startsWith('otpauth://')) {
      try {
        totp = (Uri.parse(totp).queryParameters['secret'] ?? totp).trim();
      } catch (_) {}
    }
    totp = totp.replaceAll(' ', '');
    final n = DateTime.now().millisecondsSinceEpoch;
    final entry = VaultEntry(
      id: widget.entry?.id ?? 'v_$n',
      type: _type,
      title: _title.text.trim(),
      username: _username.text.trim().isEmpty ? null : _username.text.trim(),
      secret: _secret.text,
      url: _url.text.trim().isEmpty ? null : _url.text.trim(),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      totpSecret: totp.isEmpty ? null : totp,
      createdAt: widget.entry?.createdAt ?? n,
      updatedAt: n,
    );
    try {
      if (_isEdit) {
        await VaultService.update(entry);
      } else {
        await VaultService.insert(entry);
      }
    } on VaultCorruptException {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('ভল্টের ডেটা পড়া যাচ্ছে না — সেভ হয়নি, ব্যাকআপ থেকে রিস্টোর করো')));
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  void _generate() {
    setState(() {
      _secret.text = PasswordGenerator.generate(length: 18);
      _obscure = false;
    });
  }

  /// QR স্ক্যানের মান বসায়: otpauth:// লিংক হলে secret বের করে, শিরোনাম/
  /// ইউজারনেম ফাঁকা থাকলে লেবেল থেকে সাজেস্ট করে; শুধু secret স্ক্যান
  /// হলেও সরাসরি বসে।
  void _applyScanned(String raw) {
    var secret = raw.trim();
    String? issuer;
    String? account;
    if (raw.startsWith('otpauth://')) {
      try {
        final uri = Uri.parse(raw);
        secret = (uri.queryParameters['secret'] ?? '').trim();
        issuer = uri.queryParameters['issuer'];
        final label = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
        if (label.contains(':')) {
          final parts = label.split(':');
          issuer ??= parts.first.trim();
          account = parts.sublist(1).join(':').trim();
        } else if (label.isNotEmpty) {
          account = label.trim();
        }
      } catch (_) {}
    }
    if (secret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('QR থেকে TOTP secret পাওয়া যায়নি')));
      return;
    }
    setState(() {
      _totpSecret.text = secret.replaceAll(' ', '');
      if (_title.text.trim().isEmpty && (issuer ?? account) != null) {
        _title.text = (issuer ?? account)!;
      }
      if (_username.text.trim().isEmpty && account != null && account.isNotEmpty) {
        _username.text = account;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('TOTP secret বসেছে — সেভ করলেই কোড চালু হবে')));
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw != null && mounted) _applyScanned(raw);
  }

  @override
  Widget build(BuildContext context) {
    final (strengthLabel, strengthScore) = PasswordGenerator.strength(_secret.text);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(_isEdit ? 'এডিট করো' : 'নতুন এন্ট্রি'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
                : Icon(Icons.check, size: 18, color: AppTheme.accent),
            label: Text(_isEdit ? 'আপডেট' : 'সেভ', style: TextStyle(
                color: AppTheme.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!_isEdit) ...[
            _label('ধরন'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: _labels.entries.map((e) {
              final sel = _type == e.key;
              return GestureDetector(
                onTap: () => setState(() => _type = e.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? AppTheme.accent.withOpacity(0.15) : AppTheme.bg2,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: sel ? AppTheme.accent : AppTheme.border,
                        width: sel ? 2 : 1),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(e.value.$2, size: 15, color: sel ? AppTheme.accent : AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text(e.value.$1, style: TextStyle(
                        color: sel ? AppTheme.accent : AppTheme.textSecondary,
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
              );
            }).toList()),
            const SizedBox(height: 18),
          ],
          _label('শিরোনাম *'),
          const SizedBox(height: 6),
          _field(_title, _type == 'wifi' ? 'যেমন: বাসার WiFi' : 'যেমন: GitHub, Gmail'),
          const SizedBox(height: 16),

          if (_type == 'login' || _type == 'card') ...[
            _label(_type == 'card' ? 'কার্ডধারীর নাম' : 'ইউজারনেম / ইমেইল'),
            const SizedBox(height: 6),
            _field(_username, ''),
            const SizedBox(height: 16),
          ],

          _label(_secretLabel),
          const SizedBox(height: 6),
          TextField(
            controller: _secret,
            obscureText: _type != 'note' && _obscure,
            maxLines: _type == 'note' ? 5 : 1,
            style: TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace'),
            decoration: InputDecoration(
              filled: true, fillColor: AppTheme.bg2,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppTheme.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
              contentPadding: const EdgeInsets.all(12),
              suffixIcon: _type == 'note' ? null : Row(mainAxisSize: MainAxisSize.min, children: [
                if (_type == 'login' || _type == 'wifi')
                  IconButton(icon: Icon(Icons.casino_outlined, size: 18, color: AppTheme.textMuted),
                      tooltip: 'জেনারেট করো', onPressed: _generate),
                IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18, color: AppTheme.textMuted),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ]),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if ((_type == 'login' || _type == 'wifi') && _secret.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: strengthScore, minHeight: 4,
                      backgroundColor: AppTheme.bg3,
                      valueColor: AlwaysStoppedAnimation(
                          strengthScore >= 1 ? AppTheme.green
                              : strengthScore >= 0.6 ? AppTheme.yellow : AppTheme.danger)),
                ),
              ),
              const SizedBox(width: 8),
              Text(strengthLabel, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ]),
          ],
          const SizedBox(height: 16),

          if (_type == 'login') ...[
            _label('URL (ঐচ্ছিক)'),
            const SizedBox(height: 6),
            _field(_url, 'https://...'),
            const SizedBox(height: 16),
            _label('2FA / TOTP secret (ঐচ্ছিক)'),
            const SizedBox(height: 6),
            _field(_totpSecret, 'Base32 secret — QR কোডের বদলে ম্যানুয়ালি দিলে'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _scanQr,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('QR কোড স্ক্যান করো'),
            ),
            const SizedBox(height: 16),
          ],

          _label('নোট (ঐচ্ছিক)'),
          const SizedBox(height: 6),
          _field(_notes, _type == 'card' ? 'Expiry, CVV ইত্যাদি' : 'অতিরিক্ত তথ্য', maxLines: 3),
        ]),
      ),
    );
  }

  Widget _label(String text) => Text(text, style: TextStyle(
      color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w700));

  Widget _field(TextEditingController ctrl, String hint, {int maxLines = 1}) => TextField(
    controller: ctrl, maxLines: maxLines,
    style: TextStyle(color: AppTheme.textPrimary),
    decoration: InputDecoration(
      hintText: hint, hintStyle: TextStyle(color: AppTheme.textMuted),
      filled: true, fillColor: AppTheme.bg2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppTheme.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.accent, width: 2)),
      contentPadding: const EdgeInsets.all(12),
    ),
  );
}
