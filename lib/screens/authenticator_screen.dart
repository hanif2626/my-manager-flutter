import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/vault_entry.dart';
import '../services/bubble_picker.dart';
import '../services/secure_screen.dart';
import '../services/totp_entry.dart';
import '../services/vault_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/totp_code.dart';
import 'qr_scan_screen.dart';

/// Google Authenticator-style list: every vault entry that carries a
/// TOTP secret, with big live codes, countdown rings and tap-to-copy.
/// নতুন কোড এখান থেকেই + বোতামে যোগ হয় (QR স্ক্যান/স্ক্রিনশট/সিক্রেট কী) —
/// ভল্টে আলাদা করে যেতে হয় না।
class AuthenticatorScreen extends StatefulWidget {
  const AuthenticatorScreen({super.key});
  @override State<AuthenticatorScreen> createState() => _AuthenticatorScreenState();
}

class _AuthenticatorScreenState extends State<AuthenticatorScreen> {
  List<VaultEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SecureScreen.on(); // কোড দেখা যাচ্ছে — স্ক্রিনশট/থাম্বনেইল বন্ধ
    _load();
  }

  @override
  void dispose() {
    SecureScreen.off();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await VaultService.getAll();
    final withTotp = list
        .where((e) => e.totpSecret != null && e.totpSecret!.isNotEmpty)
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    if (mounted) {
      setState(() { _entries = withTotp; _loading = false; });
    }
  }

  void _copy(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('কোড কপি হয়েছে — ৩০ সেকেন্ড পর ক্লিপবোর্ড খালি হয়ে যাবে'),
      backgroundColor: AppTheme.accent, duration: Duration(seconds: 2),
    ));
    // Copied code shouldn't sit in the clipboard — auto-clear like the vault.
    Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == code) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// পার্স করা TOTP যাচাই করে সেভ করে; সফল হলে তালিকা নতুন করে আনে।
  Future<void> _addTotp(TotpInput input) async {
    if (input.secret.isEmpty) {
      _snack('QR থেকে TOTP secret পাওয়া যায়নি');
      return;
    }
    if (!totpSecretValid(input.secret)) {
      _snack('সিক্রেট কীটা ঠিক মনে হচ্ছে না — আবার দেখো');
      return;
    }
    try {
      final saved = await saveTotpEntry(input);
      if (!mounted) return;
      await _load();
      _snack('যোগ হয়েছে — ${saved.username ?? saved.title}-এর কোড চালু');
    } on VaultCorruptException {
      _snack('ভল্টের ডেটা পড়া যাচ্ছে না — সেভ হয়নি, ব্যাকআপ থেকে রিস্টোর করো');
    } catch (e) {
      _snack('সেভ করা যায়নি: $e');
    }
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw != null && mounted) await _addTotp(parseTotpInput(raw));
  }

  /// গ্যালারির ছবি (QR-এর স্ক্রিনশট) থেকে QR পড়া — একই ফোনে সেটআপের পথ।
  Future<void> _scanQrFromGallery() async {
    try {
      final picked = await BubblePicker.pickImage(
          source: ImageSource.gallery, imageQuality: 100);
      if (picked == null || !mounted) return;
      final capture = await MobileScannerController().analyzeImage(picked.path);
      String? raw;
      if (capture != null) {
        for (final b in capture.barcodes) {
          if (b.rawValue != null && b.rawValue!.isNotEmpty) {
            raw = b.rawValue;
            break;
          }
        }
      }
      if (!mounted) return;
      if (raw == null) {
        _snack('এই ছবিতে কোনো QR কোড পাওয়া যায়নি — QR-সহ স্ক্রিনশটটা বাছো');
        return;
      }
      await _addTotp(parseTotpInput(raw));
    } catch (e) {
      if (mounted) _snack('ছবি পড়া যায়নি: $e');
    }
  }

  Future<void> _manualAdd() async {
    final account = TextEditingController();
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('সিক্রেট কী দিয়ে যোগ করো'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: account,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'অ্যাকাউন্টের নাম / ইমেইল',
              hintText: 'যেমন: hsarder43@gmail.com',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: key,
            decoration: const InputDecoration(
              labelText: 'সিক্রেট কী',
              hintText: 'Google-এর দেওয়া কী (স্পেসসহ হলেও চলবে)',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('যোগ করো', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    final acc = account.text.trim();
    final secret = key.text.trim();
    account.dispose();
    key.dispose();
    if (ok != true || !mounted) return;
    await _addTotp(TotpInput(secret.replaceAll(' ', ''), null, acc.isEmpty ? null : acc));
  }

  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.bg2,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.qr_code_scanner, color: AppTheme.accent),
            title: const Text('QR কোড স্ক্যান করো'),
            onTap: () {
              Navigator.pop(ctx);
              _scanQr();
            },
          ),
          ListTile(
            leading: Icon(Icons.photo_library_outlined, color: AppTheme.accent),
            title: const Text('গ্যালারি থেকে QR পড়ো (স্ক্রিনশট)'),
            onTap: () {
              Navigator.pop(ctx);
              _scanQrFromGallery();
            },
          ),
          ListTile(
            leading: Icon(Icons.key_outlined, color: AppTheme.accent),
            title: const Text('সিক্রেট কী লিখে যোগ করো'),
            onTap: () {
              Navigator.pop(ctx);
              _manualAdd();
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Authenticator')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.accent,
        foregroundColor: Colors.white,
        onPressed: _addSheet,
        icon: const Icon(Icons.add),
        label: const Text('যোগ করো'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : _entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      'এখনো কোনো 2FA কোড যোগ হয়নি।\nনিচের + বোতাম চেপে QR স্ক্যান, স্ক্রিনশট বা সিক্রেট কী দিয়ে যোগ করো।',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textMuted, height: 1.5),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
                  itemCount: _entries.length,
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.title, style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontWeight: FontWeight.w700, fontSize: 15)),
                                if (e.username != null && e.username!.isNotEmpty)
                                  Text(e.username!, style: TextStyle(
                                      color: AppTheme.textMuted, fontSize: 12)),
                              ],
                            ),
                          ),
                          TotpCode(secret: e.totpSecret!, large: true, onCopy: _copy),
                        ]),
                      ),
                    );
                  },
                ),
    );
  }
}
