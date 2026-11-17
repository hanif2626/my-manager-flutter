import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/secure_screen.dart';
import '../services/settings_service.dart';
import '../services/vault_pattern_service.dart';
import '../widgets/app_theme.dart';

enum PatternLockMode { setup, unlock }

/// ভল্টের প্যাটার্ন লকের পর্দা — setup: দুবার এঁকে সেট করা;
/// unlock: এঁকে যাচাই। unlock-এ ফিঙ্গারপ্রিন্ট বিকল্প পথ হিসেবে
/// থাকে, যাতে প্যাটার্ন ভুলে গেলেও নিজের ভল্টে আটকে না যান।
/// সফল হলে true নিয়ে pop করে, বাতিল/ব্যর্থ হলে false/null।
class PatternLockScreen extends StatefulWidget {
  final PatternLockMode mode;
  const PatternLockScreen({super.key, required this.mode});

  @override
  State<PatternLockScreen> createState() => _PatternLockScreenState();
}

class _PatternLockScreenState extends State<PatternLockScreen> {
  static const _lockoutKey = 'vault_pattern_lockout_ms';
  final List<int> _sel = [];
  Offset? _finger;
  List<int>? _firstDraw;
  String _msg = '';
  bool _error = false;
  int _attempts = 0;
  bool _wasLocked = false;
  Timer? _timer;

  bool get _isSetup => widget.mode == PatternLockMode.setup;

  int get _lockoutLeft {
    final until = SettingsService.getInt(_lockoutKey);
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? (left / 1000).ceil() : 0;
  }

  @override
  void initState() {
    super.initState();
    SecureScreen.on();
    _msg = _isSetup
        ? 'নতুন প্যাটার্ন আঁকো (অন্তত ৪টা বিন্দু)'
        : 'ভল্ট খুলতে প্যাটার্ন আঁকো';
    _wasLocked = _lockoutLeft > 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final locked = _lockoutLeft > 0;
      if (mounted && (locked || _wasLocked)) {
        _wasLocked = locked;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    SecureScreen.off();
    super.dispose();
  }

  bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onPoint(Offset p, double cell) {
    if (_lockoutLeft > 0) return;
    _finger = p;
    for (var i = 0; i < 9; i++) {
      final c = Offset((i % 3) * cell + cell / 2, (i ~/ 3) * cell + cell / 2);
      if ((p - c).distance <= cell * 0.38 && !_sel.contains(i)) {
        if (_sel.isNotEmpty) {
          // মাঝের বিন্দু লাফিয়ে গেলে সেটাও নিজে থেকে যোগ হয়
          // (ফোনের প্যাটার্ন লকের মতোই)।
          final last = _sel.last;
          final lr = last ~/ 3, lc = last % 3, nr = i ~/ 3, nc = i % 3;
          final dr = (lr - nr).abs(), dc = (lc - nc).abs();
          if ((dr == 2 && dc == 0) || (dr == 0 && dc == 2) || (dr == 2 && dc == 2)) {
            final mid = ((lr + nr) ~/ 2) * 3 + ((lc + nc) ~/ 2);
            if (!_sel.contains(mid)) _sel.add(mid);
          }
        }
        _sel.add(i);
        break;
      }
    }
    setState(() {});
  }

  Future<void> _onEnd() async {
    final drawn = List<int>.from(_sel);
    setState(() {
      _sel.clear();
      _finger = null;
    });
    if (drawn.isEmpty) return;
    if (drawn.length < VaultPatternService.minDots) {
      setState(() {
        _error = true;
        _msg = 'অন্তত ৪টা বিন্দু যোগ করে আঁকো';
      });
      return;
    }
    if (_isSetup) {
      if (_firstDraw == null) {
        setState(() {
          _firstDraw = drawn;
          _error = false;
          _msg = 'নিশ্চিত করতে আবার একই প্যাটার্ন আঁকো';
        });
        return;
      }
      if (_eq(_firstDraw!, drawn)) {
        await VaultPatternService.setPattern(drawn);
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _firstDraw = null;
          _error = true;
          _msg = 'দুটো প্যাটার্ন মেলেনি — আবার শুরু করো';
        });
      }
      return;
    }
    final ok = await VaultPatternService.verify(drawn);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
      return;
    }
    _attempts++;
    if (_attempts >= 5) {
      await SettingsService.setInt(
          _lockoutKey, DateTime.now().millisecondsSinceEpoch + 30000);
      _attempts = 0;
      setState(() {
        _error = true;
        _msg = '৫ বার ভুল — ৩০ সেকেন্ড পর আবার চেষ্টা করো';
      });
    } else {
      setState(() {
        _error = true;
        _msg = 'প্যাটার্ন মেলেনি — আবার আঁকো (${5 - _attempts} বার সুযোগ বাকি)';
      });
    }
  }

  Future<void> _fingerprint() async {
    final ok = await AuthService.authenticate(
        reason: 'প্যাটার্নের বদলে ফিঙ্গারপ্রিন্ট দিয়ে ভল্ট খোলো');
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockoutLeft > 0;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(_isSetup ? 'প্যাটার্ন লক সেট করো' : 'প্যাটার্ন আঁকো'),
        backgroundColor: AppTheme.bg2,
      ),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 28),
          Icon(Icons.pattern, size: 40, color: AppTheme.accent),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              locked ? 'অনেকবার ভুল হয়েছে — $_lockoutLeft সেকেন্ড অপেক্ষা করো' : _msg,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error || locked ? AppTheme.red : AppTheme.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: LayoutBuilder(builder: (ctx, cons) {
              final size = cons.maxWidth > 320 ? 320.0 : cons.maxWidth - 48;
              final cell = size / 3;
              return SizedBox(
                width: size,
                height: size,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _onPoint(d.localPosition, cell),
                  onPanUpdate: (d) => _onPoint(d.localPosition, cell),
                  onPanEnd: (_) => _onEnd(),
                  child: CustomPaint(
                    painter: _PatternPainter(
                      sel: List<int>.from(_sel),
                      finger: _finger,
                      cell: cell,
                      color: _error ? AppTheme.red : AppTheme.accent,
                      muted: AppTheme.textMuted,
                    ),
                  ),
                ),
              );
            }),
          ),
          const Spacer(),
          if (!_isSetup)
            TextButton.icon(
              onPressed: _fingerprint,
              icon: const Icon(Icons.fingerprint, size: 20),
              label: const Text('ফিঙ্গারপ্রিন্ট দিয়ে খোলো'),
            ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  final List<int> sel;
  final Offset? finger;
  final double cell;
  final Color color;
  final Color muted;

  _PatternPainter({
    required this.sel,
    required this.finger,
    required this.cell,
    required this.color,
    required this.muted,
  });

  Offset _c(int i) =>
      Offset((i % 3) * cell + cell / 2, (i ~/ 3) * cell + cell / 2);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (var k = 0; k + 1 < sel.length; k++) {
      canvas.drawLine(_c(sel[k]), _c(sel[k + 1]), line);
    }
    if (sel.isNotEmpty && finger != null) {
      canvas.drawLine(_c(sel.last), finger!, line);
    }
    for (var i = 0; i < 9; i++) {
      final c = _c(i);
      final active = sel.contains(i);
      canvas.drawCircle(
          c, active ? 13 : 9, Paint()..color = active ? color : muted.withOpacity(0.35));
      canvas.drawCircle(c, active ? 5 : 3, Paint()..color = Colors.white.withOpacity(0.9));
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.sel.length != sel.length || old.finger != finger || old.color != color;
}
