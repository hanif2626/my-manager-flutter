import 'package:flutter/material.dart';
import '../widgets/app_theme.dart';
import '../services/settings_service.dart';
import '../reminder/models/reminder.dart' show bn;
import '../reminder/screens/reminder_screen.dart';
import '../reminder/services/reminder_service.dart';
import '../jobs/screens/job_hub_screen.dart';
import '../family/screens/family_home_screen.dart';
import '../backup/backup_center_screen.dart';
import '../docs/screens/docs_home_screen.dart';
import '../screentime/screen_time_screen.dart';
import '../today/today_card.dart';
import '../today/today_screen.dart';

class _Module {
  final String name;
  final IconData icon;
  final Color color;
  final bool ready;
  const _Module(this.name, this.icon, this.color, {this.ready = false});
}

const _readyModules = <String>{'ক্যাশবুক', 'ভল্ট', 'Authenticator', 'প্রজেক্ট', 'চাকরি হাব', 'পরিবার', 'ডকুমেন্ট ও তথ্য', 'স্ক্রিন টাইম', 'রিমাইন্ডার', 'ব্যাকআপ', 'সেটিংস'};

const _modules = [
  _Module('ক্যাশবুক', Icons.account_balance_wallet, Color(0xFF4F46E5), ready: true),
  _Module('ভল্ট', Icons.lock, Color(0xFF15803D), ready: true),
  _Module('Authenticator', Icons.qr_code_2_outlined, Color(0xFF0E7C86), ready: true),
  _Module('প্রজেক্ট', Icons.folder, Color(0xFFB45309), ready: true),
  _Module('চাকরি হাব', Icons.work_outline_rounded, Color(0xFF38BDF8), ready: true),
  _Module('রিমাইন্ডার', Icons.notifications_active, Color(0xFFFBBF24), ready: true),
  _Module('পরিবার', Icons.family_restroom, Color(0xFFDC4C4C), ready: true),
  _Module('ডকুমেন্ট ও তথ্য', Icons.folder_special, Color(0xFF4ADE80), ready: true),
  _Module('স্ক্রিন টাইম', Icons.phone_android_rounded, Color(0xFFF59E0B), ready: true),
  _Module('ব্যাকআপ', Icons.cloud_sync_rounded, Color(0xFF38BDF8), ready: true),
  _Module('সেটিংস', Icons.settings, Color(0xFF9A9AA5), ready: true),
];

class LifeHomeScreen extends StatefulWidget {
  final VoidCallback onOpenProjects;
  final VoidCallback onOpenVault;
  final VoidCallback onOpenCashbook;
  final VoidCallback onOpenAuthenticator;
  final VoidCallback onOpenSettings;
  final VoidCallback onThemeToggle;

  const LifeHomeScreen({
    super.key,
    required this.onOpenProjects,
    required this.onOpenVault,
    required this.onOpenCashbook,
    required this.onOpenAuthenticator,
    required this.onOpenSettings,
    required this.onThemeToggle,
  });

  @override
  State<LifeHomeScreen> createState() => _LifeHomeScreenState();
}

class _LifeHomeScreenState extends State<LifeHomeScreen> {
  bool _isDark = SettingsService.isDark;
  int _remCount = 0;
  int _todayTick = 0; // বদলালে আজকের কার্ড নতুন করে লোড হয়

  @override
  void initState() {
    super.initState();
    _loadRemCount();
    ReminderService.changes.addListener(_loadRemCount);
  }

  @override
  void dispose() {
    ReminderService.changes.removeListener(_loadRemCount);
    super.dispose();
  }

  Future<void> _loadRemCount() async {
    try {
      final c = await ReminderService.pendingTodayCount();
      if (mounted && c != _remCount) setState(() => _remCount = c);
    } catch (_) {}
  }

  void _refreshToday() {
    if (mounted) setState(() => _todayTick++);
  }

  /// আজকের ম্যানেজার স্ক্রিন থেকে কোনো আইটেমে ট্যাপ করলে — ট্যাব-বদলানো মডিউলগুলোর
  /// (প্রজেক্ট/ভল্ট/ক্যাশবুক) আগে এই স্ক্রিন বন্ধ করে, বাকিগুলো উপরে খোলে।
  void _openFromToday(BuildContext todayCtx, String module, int tab) {
    switch (module) {
      case 'প্রজেক্ট':
        Navigator.pop(todayCtx);
        widget.onOpenProjects();
        return;
      case 'ক্যাশবুক':
        Navigator.pop(todayCtx);
        widget.onOpenCashbook();
        return;
      case 'ভল্ট':
        Navigator.pop(todayCtx);
        widget.onOpenVault();
        return;
      case 'রিমাইন্ডার':
        Navigator.push(todayCtx, MaterialPageRoute(builder: (_) => const ReminderScreen()))
            .then((_) { _loadRemCount(); _refreshToday(); });
        return;
      case 'চাকরি হাব':
        Navigator.push(todayCtx, MaterialPageRoute(
            builder: (_) => JobHubScreen(onOpenVault: widget.onOpenVault, initialTab: tab)));
        return;
      case 'পরিবার':
        Navigator.push(todayCtx, MaterialPageRoute(
            builder: (_) => FamilyHomeScreen(onOpenVault: widget.onOpenVault, initialTab: tab)));
        return;
      case 'ব্যাকআপ':
        Navigator.push(todayCtx, MaterialPageRoute(builder: (_) => const BackupCenterScreen()));
        return;
      case 'ডকুমেন্ট ও তথ্য':
        Navigator.push(todayCtx, MaterialPageRoute(builder: (_) => const DocsHomeScreen()));
        return;
      case 'স্ক্রিন টাইম':
        Navigator.push(todayCtx, MaterialPageRoute(builder: (_) => const ScreenTimeScreen()));
        return;
    }
  }

  void _tap(BuildContext context, _Module m) {
    switch (m.name) {
      case 'প্রজেক্ট': widget.onOpenProjects(); return;
      case 'ভল্ট': widget.onOpenVault(); return;
      case 'ক্যাশবুক': widget.onOpenCashbook(); return;
      case 'Authenticator': widget.onOpenAuthenticator(); return;
      case 'রিমাইন্ডার':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ReminderScreen()))
            .then((_) => _loadRemCount());
        return;
      case 'চাকরি হাব':
        Navigator.push(context, MaterialPageRoute(
            builder: (_) => JobHubScreen(onOpenVault: widget.onOpenVault)))
            .then((_) { _loadRemCount(); _refreshToday(); });
        return;
      case 'পরিবার':
        Navigator.push(context, MaterialPageRoute(
            builder: (_) => FamilyHomeScreen(onOpenVault: widget.onOpenVault)))
            .then((_) { _loadRemCount(); _refreshToday(); });
        return;
      case 'ব্যাকআপ':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupCenterScreen()))
            .then((_) => _refreshToday());
        return;
      case 'ডকুমেন্ট ও তথ্য':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const DocsHomeScreen()))
            .then((_) => _refreshToday());
        return;
      case 'স্ক্রিন টাইম':
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ScreenTimeScreen()))
            .then((_) => _refreshToday());
        return;
      case 'সেটিংস': widget.onOpenSettings(); return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('🚧 ${m.name}'),
        content: const Text('এই মডিউলটা এখনো তৈরি হচ্ছে — শীঘ্রই আসছে!'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Stack(children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
                child: SizedBox(
                  height: 190,
                  width: double.infinity,
                  child: Image.network(
                    'https://images.unsplash.com/photo-1754206352278-21910fa23063?auto=format&fit=crop&w=1200&q=70',
                    fit: BoxFit.cover,
                    // No internet or the photo host is unreachable — fall
                    // back to a painted approximation rather than a blank/
                    // broken image.
                    errorBuilder: (_, __, ___) => CustomPaint(painter: _SunriseBannerPainter()),
                    loadingBuilder: (context, child, progress) =>
                        progress == null ? child : CustomPaint(painter: _SunriseBannerPainter()),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 16, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('আমার জীবন', style: AppTheme.display(size: 24, color: Colors.white)
                          .copyWith(shadows: const [Shadow(blurRadius: 8, color: Colors.black45)])),
                      const SizedBox(height: 4),
                      Text('জীবনকে সাজাও, এক অ্যাপে',
                          style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.9),
                              shadows: const [Shadow(blurRadius: 6, color: Colors.black45)])),
                    ]),
                  ),
                  _headerIconButton(
                    icon: _isDark ? Icons.dark_mode : Icons.light_mode,
                    color: _isDark ? AppTheme.accent : AppTheme.yellow,
                    onTap: () async {
                      await SettingsService.setDark(!SettingsService.isDark);
                      if (!mounted) return;
                      setState(() => _isDark = SettingsService.isDark);
                      widget.onThemeToggle();
                    },
                  ),
                  const SizedBox(width: 8),
                  _headerIconButton(
                    icon: Icons.settings_outlined,
                    color: AppTheme.textSecondary,
                    onTap: widget.onOpenSettings,
                  ),
                ]),
              ),
            ]),
          ),
          SliverToBoxAdapter(
            child: TodayCard(
              key: ValueKey(_todayTick),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => TodayScreen(onOpen: _openFromToday)),
              ).then((_) => _refreshToday()),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.85,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final m = _modules[i];
                  return _ModuleCard(
                    module: m,
                    badge: m.name == 'রিমাইন্ডার' ? _remCount : 0,
                    onTap: () => _tap(context, m),
                  );
                },
                childCount: _modules.length,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _headerIconButton({required IconData icon, required Color color, required VoidCallback onTap}) {
    return Material(
      color: AppTheme.bg2,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

class _SunriseBannerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizon = h * 0.62;

    // Sky: deep indigo at top fading through pink to warm orange at the horizon.
    final skyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFF241B4E), Color(0xFF6B2E64), Color(0xFFE07A4F), Color(0xFFF7C873)],
        stops: [0.0, 0.45, 0.78, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, horizon));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, horizon), skyPaint);

    // Sun: soft glow behind a solid disc, sitting right on the horizon.
    final sunCenter = Offset(w * 0.74, horizon - 6);
    final glow = Paint()
      ..shader = RadialGradient(colors: [
        const Color(0xFFFFE9B0).withOpacity(0.55), const Color(0xFFFFE9B0).withOpacity(0.0),
      ]).createShader(Rect.fromCircle(center: sunCenter, radius: 55));
    canvas.drawCircle(sunCenter, 55, glow);
    canvas.drawCircle(sunCenter, 22, Paint()..color = const Color(0xFFFFF2CC));

    // Water below the horizon, catching the same warm light.
    final waterPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xFFE0895A), Color(0xFF2E2350)],
      ).createShader(Rect.fromLTWH(0, horizon, w, h - horizon));
    canvas.drawRect(Rect.fromLTWH(0, horizon, w, h - horizon), waterPaint);

    // Sun's reflection as a soft vertical streak on the water.
    canvas.drawRect(
      Rect.fromLTWH(sunCenter.dx - 10, horizon, 20, h - horizon),
      Paint()..color = const Color(0xFFFFE9B0).withOpacity(0.35),
    );

    // Two layered mountain silhouettes for depth.
    final farMountain = Path()
      ..moveTo(0, horizon)
      ..lineTo(w * 0.18, horizon - 46)
      ..lineTo(w * 0.34, horizon - 14)
      ..lineTo(w * 0.52, horizon - 58)
      ..lineTo(w * 0.68, horizon - 20)
      ..lineTo(w, horizon - 40)
      ..lineTo(w, horizon)
      ..close();
    canvas.drawPath(farMountain, Paint()..color = const Color(0xFF3B2A55).withOpacity(0.85));

    final nearMountain = Path()
      ..moveTo(0, horizon)
      ..lineTo(w * 0.12, horizon - 22)
      ..lineTo(w * 0.30, horizon - 62)
      ..lineTo(w * 0.46, horizon - 18)
      ..lineTo(w * 0.60, horizon - 50)
      ..lineTo(w * 0.82, horizon - 10)
      ..lineTo(w, horizon - 30)
      ..lineTo(w, horizon)
      ..close();
    canvas.drawPath(nearMountain, Paint()..color = const Color(0xFF241A3D));

    // Dark scrim over the whole banner so white header text stays readable.
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black.withOpacity(0.18));
  }

  @override
  bool shouldRepaint(covariant _SunriseBannerPainter oldDelegate) => false;
}

class _ModuleCard extends StatelessWidget {
  final _Module module;
  final VoidCallback onTap;
  final int badge;
  const _ModuleCard({required this.module, required this.onTap, this.badge = 0});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bg2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: AppTheme.border)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: module.ready ? module.color.withOpacity(0.15) : AppTheme.bg3,
                  shape: BoxShape.circle,
                ),
                child: Icon(module.icon, color: module.ready ? module.color : AppTheme.textMuted, size: 22),
              ),
              if (badge > 0)
                Positioned(
                  right: -6, top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(color: AppTheme.red, borderRadius: BorderRadius.circular(10)),
                    child: Text(bn(badge > 99 ? 99 : badge),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (!module.ready)
                Positioned(
                  right: -2, top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: AppTheme.bg2, shape: BoxShape.circle),
                    child: Icon(Icons.lock_clock, size: 13, color: AppTheme.textMuted),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text(module.name,
                textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600,
                    color: module.ready ? AppTheme.textPrimary : AppTheme.textMuted)),
            if (!module.ready)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('শীঘ্রই', style: TextStyle(fontSize: 9.5, color: AppTheme.textMuted)),
              ),
          ]),
        ),
      ),
    );
  }
}
