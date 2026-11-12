import 'package:flutter/material.dart';
import '../../widgets/app_theme.dart';

/// A calculator that behaves like the stock Android calculator: you keep
/// typing a whole expression (12+45×2), '=' evaluates it and lets you
/// keep chaining off the result, and AC/⌫/%/± work the way people
/// already expect. Returns the final numeric value via Navigator.pop
/// when the user taps "পরিমাণে বসাও"; tapping ✕ or outside the sheet
/// closes without returning anything.
class CalculatorSheet extends StatefulWidget {
  const CalculatorSheet({super.key});

  static Future<double?> show(BuildContext context) {
    return showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const CalculatorSheet(),
    );
  }

  @override
  State<CalculatorSheet> createState() => _CalculatorSheetState();
}

class _CalculatorSheetState extends State<CalculatorSheet> {
  String _expr = '';
  String _history = '';
  bool _justEvaluated = false;

  static const _ops = ['÷', '×', '−', '+'];

  String? _lastNumberToken() {
    final m = RegExp(r'(\d+\.?\d*)$').firstMatch(_expr);
    return m?.group(0);
  }

  void _press(String k) {
    setState(() {
      if (k == 'AC') {
        _expr = '';
        _history = '';
        _justEvaluated = false;
      } else if (k == '⌫') {
        if (_expr.isNotEmpty) _expr = _expr.substring(0, _expr.length - 1);
        _justEvaluated = false;
      } else if (k == '%') {
        final tok = _lastNumberToken();
        if (tok != null) {
          final v = (double.tryParse(tok) ?? 0) / 100;
          _expr = _expr.substring(0, _expr.length - tok.length) + _fmtNum(v);
        }
      } else if (k == '±') {
        final tok = _lastNumberToken();
        if (tok != null) {
          final before = _expr.substring(0, _expr.length - tok.length);
          if (before.endsWith('(-') && before.length >= 2) {
            _expr = before.substring(0, before.length - 2) + tok;
          } else {
            _expr = '$before(-$tok)';
          }
        }
      } else if (_ops.contains(k)) {
        _justEvaluated = false;
        if (_expr.isEmpty) {
          if (k == '−') _expr = k; // allow starting a negative number
          return;
        }
        final lastCh = _expr[_expr.length - 1];
        if (_ops.contains(lastCh)) {
          _expr = _expr.substring(0, _expr.length - 1) + k;
        } else {
          _expr += k;
        }
      } else if (k == '.') {
        final tok = _lastNumberToken() ?? '';
        if (!tok.contains('.')) _expr += tok.isEmpty ? '0.' : '.';
        _justEvaluated = false;
      } else if (k == '=') {
        final val = _evaluate(_expr);
        if (val != null) {
          _history = '${_display(_expr)} =';
          _expr = _fmtNum(val);
          _justEvaluated = true;
        }
      } else {
        // digit
        if (_justEvaluated) {
          _expr = '';
          _history = '';
          _justEvaluated = false;
        }
        _expr += k;
      }
    });
  }

  double? _evaluate(String expr) {
    if (expr.isEmpty) return null;
    final safe = expr.replaceAll('×', '*').replaceAll('÷', '/').replaceAll('−', '-');
    try {
      final r = _evalMath(safe);
      // ৫÷০ = Infinity, ০÷০ = NaN — এগুলো ফলাফল নয়; null ফেরালে পরিমাণে
      // বসবে না (আগে Infinity এন্ট্রি শিটে গিয়ে roundToDouble-এ ক্র্যাশ করত)।
      return (r == null || !r.isFinite) ? null : r;
    } catch (_) {
      return null;
    }
  }

  /// A tiny recursive-descent evaluator for +,-,*,/ and parentheses —
  /// avoids pulling in a whole expression-parsing package for four
  /// operators. Implemented as instance methods (not nested local
  /// functions) because parseExpr/parseTerm/parseFactor call each other
  /// circularly, and Dart's local function declarations can't
  /// forward-reference one another the way class methods can.
  late String _evalStr;
  late int _evalPos;

  double _evalMath(String s) {
    _evalStr = s;
    _evalPos = 0;
    return _parseExpr();
  }

  double _parseExpr() {
    double v = _parseTerm();
    while (_evalPos < _evalStr.length && (_evalStr[_evalPos] == '+' || _evalStr[_evalPos] == '-')) {
      final op = _evalStr[_evalPos++];
      final rhs = _parseTerm();
      v = op == '+' ? v + rhs : v - rhs;
    }
    return v;
  }

  double _parseTerm() {
    double v = _parseFactor();
    while (_evalPos < _evalStr.length && (_evalStr[_evalPos] == '*' || _evalStr[_evalPos] == '/')) {
      final op = _evalStr[_evalPos++];
      final rhs = _parseFactor();
      v = op == '*' ? v * rhs : v / rhs;
    }
    return v;
  }

  double _parseFactor() {
    if (_evalPos < _evalStr.length && _evalStr[_evalPos] == '-') {
      _evalPos++;
      return -_parseFactor();
    }
    if (_evalPos < _evalStr.length && _evalStr[_evalPos] == '(') {
      _evalPos++;
      final v = _parseExpr();
      if (_evalPos < _evalStr.length && _evalStr[_evalPos] == ')') _evalPos++;
      return v;
    }
    final start = _evalPos;
    while (_evalPos < _evalStr.length && RegExp(r'[0-9.]').hasMatch(_evalStr[_evalPos])) {
      _evalPos++;
    }
    return double.parse(_evalStr.substring(start, _evalPos));
  }

  String _fmtNum(double v) {
    if (!v.isFinite) return '';
    final rounded = (v * 100).round() / 100;
    return rounded == rounded.roundToDouble()
        ? rounded.toInt().toString()
        : rounded.toString();
  }

  String _display(String expr) => expr.replaceAllMapped(
      RegExp(r'\(-(\d+\.?\d*)\)'), (m) => '−${m.group(1)}');

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
        decoration: BoxDecoration(
          color: AppTheme.bg2,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('ক্যালকুলেটর',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: AppTheme.textMuted)),
            Row(children: [
              TextButton(
                onPressed: () {
                  final v = _evaluate(_expr) ?? double.tryParse(_expr);
                  Navigator.pop(context, v);
                },
                child: const Text('✓ পরিমাণে বসাও', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: AppTheme.bg3, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 15),
                ),
              ),
            ]),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: Text(_history.isEmpty ? ' ' : _history,
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(_expr.isEmpty ? '0' : _display(_expr),
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 14),
          _row(['AC', '⌫', '%', '÷']),
          const SizedBox(height: 8),
          _row(['7', '8', '9', '×']),
          const SizedBox(height: 8),
          _row(['4', '5', '6', '−']),
          const SizedBox(height: 8),
          _row(['1', '2', '3', '+']),
          const SizedBox(height: 8),
          _row(['±', '0', '.', '=']),
        ]),
      ),
    );
  }

  Widget _row(List<String> keys) {
    return Row(children: keys.map((k) {
      final isFn = ['AC', '⌫', '%'].contains(k);
      final isOp = _ops.contains(k);
      final isEq = k == '=';
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            color: isEq ? AppTheme.accent : (isOp ? Colors.transparent : AppTheme.bg3),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: () => _press(k),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 54,
                alignment: Alignment.center,
                decoration: isOp
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.accent, width: 1.4))
                    : null,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: isFn || isOp || isEq ? FontWeight.w700 : FontWeight.w600,
                        color: isEq
                            ? Colors.white
                            : isOp || isFn
                                ? AppTheme.accent
                                : AppTheme.textPrimary)),
              ),
            ),
          ),
        ),
      );
    }).toList());
  }
}
