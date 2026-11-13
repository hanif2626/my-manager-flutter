import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart' as otplib;
import 'app_theme.dart';

/// Live TOTP code (Google Authenticator-style "123 456") with a
/// 30-second countdown ring. The ring turns red in the last 5 seconds.
/// Tap copies the code — via [onCopy] when given, so callers can reuse
/// their clipboard auto-clear flow; otherwise copies directly.
class TotpCode extends StatefulWidget {
  final String secret;
  final bool large;
  final void Function(String code)? onCopy;
  const TotpCode({super.key, required this.secret, this.large = false, this.onCopy});
  @override State<TotpCode> createState() => _TotpCodeState();
}

class _TotpCodeState extends State<TotpCode> {
  Timer? _timer;
  String _code = '------';
  int _remaining = 30;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  void _tick() {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final code = otplib.OTP.generateTOTPCodeString(
          widget.secret, now,
          length: 6, interval: 30, algorithm: otplib.Algorithm.SHA1, isGoogle: true);
      final rem = 30 - ((now ~/ 1000) % 30);
      if (mounted && (code != _code || rem != _remaining)) {
        setState(() { _code = code; _remaining = rem; });
      }
    } catch (_) {}
  }

  String get _grouped =>
      _code.length == 6 ? '${_code.substring(0, 3)} ${_code.substring(3)}' : _code;

  void _tap() {
    if (_code == '------') return;
    if (widget.onCopy != null) {
      widget.onCopy!(_code);
      return;
    }
    Clipboard.setData(ClipboardData(text: _code));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('কোড কপি হয়েছে'), duration: Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final ring = widget.large ? 26.0 : 16.0;
    return InkWell(
      onTap: _tap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_grouped, style: TextStyle(
              color: AppTheme.accent, fontWeight: FontWeight.w700,
              fontSize: widget.large ? 22 : 13.5, letterSpacing: 1.2,
              fontFamily: 'monospace')),
          const SizedBox(width: 8),
          SizedBox(
            width: ring, height: ring,
            child: CircularProgressIndicator(
              value: _remaining / 30,
              strokeWidth: 2.5,
              backgroundColor: AppTheme.bg3,
              valueColor: AlwaysStoppedAnimation(
                  _remaining <= 5 ? AppTheme.danger : AppTheme.accent),
            ),
          ),
        ]),
      ),
    );
  }
}
