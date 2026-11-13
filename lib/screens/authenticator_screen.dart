import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/vault_entry.dart';
import '../services/secure_screen.dart';
import '../services/vault_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/totp_code.dart';

/// Google Authenticator-style list: every vault entry that carries a
/// TOTP secret, with big live codes, countdown rings and tap-to-copy.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('Authenticator')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.accent))
          : _entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      'এখনো কোনো 2FA কোড যোগ হয়নি।\nভল্টে একটা লগইন এন্ট্রি খুলে TOTP ঘরে QR স্ক্যান বা ম্যানুয়াল key বসালেই কোড এখানে আসবে।',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textMuted, height: 1.5),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(14),
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
