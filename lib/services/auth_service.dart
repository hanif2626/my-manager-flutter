import 'package:local_auth/local_auth.dart';

import 'bubble_window.dart';

/// Thin wrapper around local_auth for locking individual projects behind
/// the device's own fingerprint/face unlock or PIN/pattern/password —
/// deliberately not a custom in-app PIN system, since the OS already has
/// a secure, familiar one built in.
class AuthService {
  static final _auth = LocalAuthentication();

  /// True if the device has *some* way to authenticate — biometrics
  /// enrolled, or a PIN/pattern/password set. If neither is true,
  /// there's nothing to protect a project with.
  static Future<bool> canAuthenticate() async {
    try {
      final bioSupported = await _auth.canCheckBiometrics;
      final deviceSupported = await _auth.isDeviceSupported();
      return bioSupported || deviceSupported;
    } catch (_) {
      return false;
    }
  }

  /// Prompts fingerprint/face first, falling back to the device's own
  /// PIN/pattern/password if biometrics aren't set up or fail. Returns
  /// false on cancel, failure, or any plugin error — callers should
  /// treat that as "stay locked out".
  static Future<bool> authenticate({String reason = 'প্রজেক্টটা লক করা — যাচাই করো'}) async {
    // বাবলের ভাসমান উইন্ডোতে বায়োমেট্রিক চলে না (Activity লাগে) —
    // মূল অ্যাপ খুলে সেখানে যাচাই হবে।
    if (BubbleWindow.isBubble) {
      await BubbleWindow.openMainApp();
      return false;
    }
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // allow device PIN/pattern as a fallback
          stickyAuth: true,     // survive brief app backgrounding (e.g. a call)
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
