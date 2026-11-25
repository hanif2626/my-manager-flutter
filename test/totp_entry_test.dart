import 'package:flutter_test/flutter_test.dart';
import 'package:my_manager/services/totp_entry.dart';

void main() {
  test('otpauth লিংক: secret + issuer + account', () {
    final r = parseTotpInput(
        'otpauth://totp/Google:hsarder43@gmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Google');
    expect(r.secret, 'JBSWY3DPEHPK3PXP');
    expect(r.issuer, 'Google');
    expect(r.account, 'hsarder43@gmail.com');
  });

  test('otpauth লিংক: issuer প্যারামিটার ছাড়া, লেবেল থেকে', () {
    final r = parseTotpInput('otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP');
    expect(r.secret, 'JBSWY3DPEHPK3PXP');
    expect(r.issuer, 'Example');
    expect(r.account, 'alice');
  });

  test('শুধু secret (স্পেসসহ) → স্পেস বাদ', () {
    final r = parseTotpInput('JBSW Y3DP EHPK 3PXP');
    expect(r.secret, 'JBSWY3DPEHPK3PXP');
    expect(r.issuer, isNull);
    expect(r.account, isNull);
  });

  test('secret যাচাই', () {
    expect(totpSecretValid('JBSWY3DPEHPK3PXP'), true);
    expect(totpSecretValid('not a secret!!'), false);
    expect(totpSecretValid(''), false);
  });
}
