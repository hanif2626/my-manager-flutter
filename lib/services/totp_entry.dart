import 'package:otp/otp.dart' as otplib;
import '../models/vault_entry.dart';
import 'vault_service.dart';

/// Authenticator থেকে সরাসরি TOTP যোগ করার সহায়ক — ভল্টে আলাদা করে যেতে হয় না।
/// QR/পেস্ট থেকে পাওয়া তথ্য এখানে পার্স হয়ে ভল্টের এন্ট্রিতে বসে
/// (একই অ্যাকাউন্টের এন্ট্রি থাকলে তার TOTP বদলে যায়, না থাকলে নতুন এন্ট্রি হয়)।

class TotpInput {
  final String secret;
  final String? issuer;
  final String? account;
  const TotpInput(this.secret, this.issuer, this.account);
}

/// QR/পেস্ট করা লেখা থেকে TOTP তথ্য: otpauth:// লিংক হলে secret+issuer+account,
/// নইলে পুরো লেখাটাই secret ধরা হয়। স্পেস বাদ যায় (Base32-তে স্পেসের মানে নেই)।
TotpInput parseTotpInput(String raw) {
  var secret = raw.trim();
  String? issuer;
  String? account;
  if (secret.startsWith('otpauth://')) {
    try {
      final uri = Uri.parse(secret);
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
  return TotpInput(secret.replaceAll(' ', ''), issuer, account);
}

/// secret-টা দিয়ে আসলেই কোড বানানো যায় কিনা — ভুল কী সেভ হওয়া ঠেকাতে।
bool totpSecretValid(String secret) {
  if (secret.isEmpty) return false;
  try {
    otplib.OTP.generateTOTPCodeString(secret, DateTime.now().millisecondsSinceEpoch,
        length: 6, interval: 30, algorithm: otplib.Algorithm.SHA1, isGoogle: true);
    return true;
  } catch (_) {
    return false;
  }
}

/// TOTP ভল্টে বসায়। একই অ্যাকাউন্টের (ইউজারনেম মিললে) এন্ট্রি থাকলে শুধু তার
/// TOTP বদলে যায় — পাসওয়ার্ডসহ বাকি সব অক্ষত। না থাকলে নতুন লগইন এন্ট্রি
/// তৈরি হয় (পাসওয়ার্ড খালি — পরে ভল্ট থেকে বসানো যাবে)।
Future<VaultEntry> saveTotpEntry(TotpInput input) async {
  final all = await VaultService.getAll();
  final account = (input.account ?? '').trim();
  VaultEntry? match;
  for (final e in all) {
    if (account.isNotEmpty && (e.username ?? '').trim().toLowerCase() == account.toLowerCase()) {
      match = e;
      break;
    }
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  if (match != null) {
    final updated = match.copyWith(totpSecret: input.secret, updatedAt: now);
    await VaultService.update(updated);
    return updated;
  }
  final issuer = (input.issuer ?? '').trim();
  final entry = VaultEntry(
    id: 'v_$now',
    type: 'login',
    title: issuer.isNotEmpty ? issuer : (account.isNotEmpty ? account : 'Authenticator'),
    username: account.isEmpty ? null : account,
    secret: '',
    totpSecret: input.secret,
    createdAt: now,
    updatedAt: now,
  );
  await VaultService.insert(entry);
  return entry;
}
