import 'package:flutter/material.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../widgets/app_theme.dart';
import '../services/spending_guard.dart';

const _red = Color(0xFFDC2626);
const _amber = Color(0xFFF59E0B);

/// ক্যাশবুকের উপরের খরচ-প্রহরী কার্ড — শান্ত তথ্য-কার্ড: ব্যালেন্স, বাকি
/// আবশ্যিক খরচ আর নিরাপদ খরচের হিসাব। সতর্কতা অ্যাপের ভেতরে নয়,
/// নোটিফিকেশন বারে থাকে (ব্যবহারকারীর সিদ্ধান্ত, ২০২৬-১১-১১)।
class SpendingGuardCard extends StatefulWidget {
  /// "আবশ্যিক খরচ দেখো" বাটনে ট্যাপ করলে আবশ্যিক খরচ ট্যাবে যেতে।
  final VoidCallback? onOpenEssentials;
  const SpendingGuardCard({super.key, this.onOpenEssentials});
  @override State<SpendingGuardCard> createState() => _SpendingGuardCardState();
}

class _SpendingGuardCardState extends State<SpendingGuardCard> {
  GuardReport? _r;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    SpendingGuard.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    SpendingGuard.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await SpendingGuard.assess();
      if (mounted) setState(() => _r = r);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null) return const SizedBox.shrink();
    if (!SpendingGuard.enabled) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => showGuardSettings(context),
            icon: const Icon(Icons.shield_outlined, size: 16),
            label: const Text('খরচ-প্রহরী বন্ধ — চালু করো', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }
    // অ্যাপের ভেতরে আর লাল অ্যালার্ম কার্ড নয় (ব্যবহারকারীর সিদ্ধান্ত,
    // ২০২৬-১১-১১) — সব অবস্থায় এই শান্ত তথ্য-কার্ডটাই থাকে; আসল
    // সতর্কতা এখন নোটিফিকেশন বারে (SpendingGuard.syncOngoing)।
    return _calm(r);
  }

  // ───────────── সব ঠিক ─────────────

  Widget _calm(GuardReport r) {
    // কিস্তি/আবশ্যিক খরচ বাকি থাকলে টাকা যথেষ্ট হলেও কার্ড হলদে + তালিকা সবসময় খোলা।
    final pending = r.hasPending;
    final open = _open || pending;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color: (pending ? _amber : AppTheme.green).withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(pending ? Icons.push_pin_rounded : Icons.shield_rounded, size: 18, color: pending ? _amber : AppTheme.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(pending ? '${r.headline}\n${r.essentialsLine}' : r.essentialsLine,
                      maxLines: open ? 6 : 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.35)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.tune_rounded, size: 18, color: AppTheme.textMuted),
                  onPressed: () => showGuardSettings(context),
                ),
              ]),
              if (open)
                for (final l in r.detailLines)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text('• $l', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ═════════════ খরচ লেখার সময়ের "থামো" ডায়ালগ ═════════════

/// নতুন খরচ সেভের আগে: এটা করলে অবস্থা কী দাঁড়াবে দেখিয়ে লাল ডায়ালগ। ৩ সেকেন্ড ভাবার সুযোগ,
/// তারপর "দরকারি, সেভ করো" চালু হয়। true = এগোও, false/null = বাদ।
Future<bool?> showSpendingNudge(BuildContext context, GuardReport r, double amount) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _NudgeDialog(r: r, amount: amount),
  );
}

class _NudgeDialog extends StatefulWidget {
  final GuardReport r;
  final double amount;
  const _NudgeDialog({required this.r, required this.amount});
  @override State<_NudgeDialog> createState() => _NudgeDialogState();
}

class _NudgeDialogState extends State<_NudgeDialog> {
  int _left = 3;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() async {
    while (_left > 0) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _left--);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final danger = r.level == GuardLevel.danger;
    final base = danger ? _red : _amber;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [base, Color.lerp(base, Colors.black, 0.3)!],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('✋ থামো!', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text('৳${bn(widget.amount.round())} খরচ কি এখনই সত্যিই দরকার?',
              style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.w800, height: 1.3)),
          const SizedBox(height: 12),
          Text(r.headline, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('এই খরচের পরে: ${r.essentialsLine}',
              style: TextStyle(color: Colors.white.withOpacity(0.95), fontSize: 13, height: 1.4)),
          for (final l in r.detailLines.take(6))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('• $l', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12.5, height: 1.35)),
            ),
          const SizedBox(height: 14),
          const Text('একটু ভাবো: এটা না করলে কি চলে? পরে করা যায়?',
              style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: base, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('না, বাদ দিই ✓', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: _left > 0 ? null : () => Navigator.pop(context, true),
              child: Text(_left > 0 ? '⏳ ${bn(_left)} সেকেন্ড ভাবো...' : 'দরকারি, তবুও সেভ করো',
                  style: TextStyle(color: _left > 0 ? Colors.white54 : Colors.white, fontSize: 13.5)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═════════════ সেটিংস ═════════════

Future<void> showGuardSettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.bg2,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => const _GuardSettingsSheet(),
  );
}

class _GuardSettingsSheet extends StatefulWidget {
  const _GuardSettingsSheet();
  @override State<_GuardSettingsSheet> createState() => _GuardSettingsSheetState();
}

class _GuardSettingsSheetState extends State<_GuardSettingsSheet> {
  String _fmtSlot(int m) {
    final h = m ~/ 60, mm = m % 60;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '${bn(h12)}:${bn(mm.toString().padLeft(2, '0'))}';
  }

  @override
  Widget build(BuildContext context) {
    final on = SpendingGuard.enabled;
    final margin = SpendingGuard.marginPct;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('খরচ-প্রহরী', style: TextStyle(color: AppTheme.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'ক্যাশবুকে যত টাকা আছে তা থেকে বাকি আবশ্যিক খরচ মেটানোর পরে হাতে কত থাকবে হিসাব করে। '
            'আবশ্যিক খরচ (কিস্তি, হাসু, বিল) বাকি থাকলে অকারণ খরচ লেখার সময় আর প্রতিদিন ৩ বেলা সতর্ক করে। '
            'টাকা আবশ্যিক খরচের কাছাকাছি গেলে লাল সতর্কতা: "টাকা কম খরচ করুন, আবশ্যিক কাজ আগে করুন"।',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5, height: 1.45),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: on,
            activeColor: AppTheme.accent,
            title: Text('চালু', style: TextStyle(color: AppTheme.textPrimary)),
            onChanged: (v) async {
              await SpendingGuard.saveSettings(on: v);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 6),
          Text('কখন "কাছাকাছি" ধরবে', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700, fontSize: 13.5)),
          const SizedBox(height: 2),
          Text('আবশ্যিক খরচ মেটানোর পর হাতে থাকা টাকা আবশ্যিক খরচের এই % এর কম হলে',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final v in [20, 30, 50, 80])
              ChoiceChip(
                label: Text('${bn(v)}%'),
                selected: margin == v,
                showCheckmark: false,
                onSelected: (_) async {
                  await SpendingGuard.saveSettings(margin: v);
                  if (mounted) setState(() {});
                },
              ),
          ]),
          const SizedBox(height: 14),
          Text('প্রতিদিন ৩ বেলা মনে করানোর সময়', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700, fontSize: 13.5)),
          const SizedBox(height: 2),
          Text('এ মাসের কিস্তি/আবশ্যিক খরচ বাকি থাকলেই দিনে ৩ বার নোটিফিকেশন আসবে — সব মিটে গেলে আর আসবে না। সময় বদলাতে ট্যাপ করো।',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (var i = 0; i < 3; i++)
              ActionChip(
                avatar: const Icon(Icons.access_time_rounded, size: 16),
                label: Text('${SpendingGuard.slotNames[i]} ${_fmtSlot(SpendingGuard.slotMinute(i))}'),
                onPressed: () async {
                  final cur = SpendingGuard.slotMinute(i);
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
                    helpText: '${SpendingGuard.slotNames[i]}ের সতর্কতার সময়',
                  );
                  if (t == null) return;
                  await SpendingGuard.setSlotMinute(i, t.hour * 60 + t.minute);
                  if (mounted) setState(() {});
                },
              ),
          ]),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              await SpendingGuard.nudgeIfNeeded(force: true);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('পরীক্ষামূলক নোটিফিকেশন পাঠানো হয়েছে')));
              }
            },
            icon: const Icon(Icons.notifications_active_outlined, size: 18),
            label: const Text('এখনই একটা নোটিফিকেশন পরীক্ষা করো'),
          ),
        ]),
      ),
    );
  }
}
