import 'dart:async';
import 'package:flutter/material.dart';
import '../jobs/radar/radar_runner.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../widgets/app_theme.dart';
import '../services/widget_service.dart';
import '../services/auth_service.dart';
import '../cashbook/services/cashbook_service.dart';
import '../cashbook/services/cashbook_notification_service.dart';
import 'dashboard_screen.dart';
import 'backup_screen.dart';
import '../services/bubble_service.dart' as bubble_ctl;
import '../services/bubble_window.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'share_intake_screen.dart';
import 'vault_screen.dart';
import '../cashbook/screens/cashbook_screen.dart';
import 'life_home_screen.dart';
import 'authenticator_screen.dart';
import 'pattern_lock_screen.dart';
import '../services/vault_pattern_service.dart';
import '../jobs/services/app_launcher.dart';
import '../reminder/screens/reminder_screen.dart';
import '../reminder/services/reminder_service.dart';
import '../services/notification_service.dart';
import '../services/data_sync.dart';
import '../db/db_helper.dart';
import '../jobs/screens/job_hub_screen.dart';
import '../jobs/services/job_service.dart';
import '../today/today_screen.dart';
import '../backup/backup_center_screen.dart';
import '../docs/screens/docs_home_screen.dart';
import '../screentime/screen_time_screen.dart';
import '../family/screens/family_home_screen.dart';
import 'idea_detail_screen.dart';
import 'project_detail_screen.dart';
import '../services/bubble_window.dart';
import '../cashbook/services/spending_guard.dart';

/// Top-level shell: bottom navigation between Projects / Search / Vault /
/// Settings. Vault is a first-class destination of its own — a password
/// manager is a fundamentally different tool from the project/idea
/// manager the rest of this app is, so it doesn't belong tucked inside
/// Settings as just another toggle.
class HomeShell extends StatefulWidget {
  final VoidCallback onThemeToggle;
  const HomeShell({super.key, required this.onThemeToggle});
  @override State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  // Bumped whenever the app comes back to the foreground, so the Dashboard
  // tab is rebuilt from scratch and re-reads the DB — needed because an
  // idea can now be added from the floating bubble while the app was in
  // the background, and the tab wouldn't otherwise know to refresh.
  int _dashboardGen = 0;

  StreamSubscription? _shareSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initShareListener();
    // বাবল (আলাদা engine) থেকে হওয়া পরিবর্তন ধরার ওয়াচার — অ্যাপ সামনে থাকলে চলে।
    DataSync.ideasChanged.addListener(_onExternalChange);
    DataSync.start();
    ReminderService.openRequest.addListener(_openReminders);
    ReminderService.cashbookOpenRequest.addListener(_openCashbookFromNotification);
    ReminderService.targetRequest.addListener(_openPendingTarget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkBubbleTarget();
      _checkLaunchTarget();
      _checkNotificationTarget();
    });
  }

  /// বাবল থেকে কোনো কাজের জন্য (যেমন Drive সাইন-ইন) মূল অ্যাপে
  /// পাঠানো হলে, অ্যাপ পুরনো অবস্থার পেজে (যেমন খোলা প্রজেক্টে) না
  /// গিয়ে সোজা সেই কাজের পেজে খোলে।
  Future<void> _checkBubbleTarget() async {
    if (BubbleWindow.isBubble || !mounted) return;
    final t = await bubble_ctl.BubbleControl.takeBubbleTarget();
    if (t == null || !mounted) return;
    if (t == 'backup') {
      final nav = Navigator.of(context);
      nav.popUntil((r) => r.isFirst);
      nav.push(MaterialPageRoute(builder: (_) => const BackupScreen()));
    }
  }

  /// হোম-স্ক্রিন আইকনে লং-প্রেস শর্টকাট থেকে আসা গন্তব্য
  /// (এখন 'authenticator') — বাবল টার্গেটের মতোই একবার পড়লেই শেষ।
  Future<void> _checkLaunchTarget() async {
    if (BubbleWindow.isBubble || !mounted) return;
    final t = await AppLauncher.takeLaunchTarget();
    if (t == 'authenticator' && mounted) _openAuthenticator();
  }

  bool _reminderOpen = false;
  bool _targetOpen = false;

  Future<void> _checkNotificationTarget() async {
    if (BubbleWindow.isBubble || !mounted) return;
    final t = await ReminderService.launchedTarget();
    if (t == null || !mounted) return;
    await _openTarget(t);
  }

  void _openPendingTarget() {
    final t = ReminderService.pendingTarget;
    if (t == null) return;
    ReminderService.pendingTarget = null;
    _openTarget(t);
  }

  Future<void> _openTarget(String target) async {
    if (_targetOpen || !mounted) return;
    _targetOpen = true;
    try {
      if (target.startsWith('rem|')) {
        final parts = target.split('|');
        await _openReminderOrCircular(
            parts.length > 1 ? int.tryParse(parts[1]) : null);
        return;
      }
      if (target == 'cashbook_evening' || target == 'cashbook_guard') {
        await _openCashbookFromNotification();
        return;
      }
      final nav = Navigator.of(context);
      nav.popUntil((r) => r.isFirst);
      if (target == 'today_digest') {
        setState(() => _index = 0);
        await nav.push(MaterialPageRoute(
            builder: (_) => TodayScreen(onOpen: _openFromTodayNotification)));
      } else if (target == 'vault_backup') {
        await nav.push(
            MaterialPageRoute(builder: (_) => const BackupCenterScreen()));
      } else if (target == 'job_radar') {
        await nav.push(MaterialPageRoute(
            builder: (_) => JobHubScreen(onOpenVault: _openVault, initialTab: 0)));
      } else if (target.startsWith('job_item|')) {
        final url = Uri.decodeComponent(target.substring('job_item|'.length));
        await nav.push(MaterialPageRoute(
            builder: (_) => JobHubScreen(
                onOpenVault: _openVault, initialTab: 0, focusRadarUrl: url)));
      } else if (target.startsWith('job_admit')) {
        final parts = target.split('|');
        final id = parts.length > 1 ? int.tryParse(parts[1]) : null;
        await nav.push(MaterialPageRoute(
            builder: (_) => JobHubScreen(
                onOpenVault: _openVault,
                initialTab: 2,
                focusCircularId: id,
                focusCircularAction: 'admit')));
      } else if (target.startsWith('idea_')) {
        await _openIdeaById(int.tryParse(target.substring(5)));
      } else if (target.startsWith('project_')) {
        final id = int.tryParse(target.substring(8));
        // পুরনো নোটিফিকেশনে project_<ideaId+1000> থাকতে পারে।
        if (id != null && id > 1000) {
          await _openIdeaById(id - 1000);
        } else {
          await _openProjectById(id);
        }
      }
    } finally {
      _targetOpen = false;
    }
  }

  void _openFromTodayNotification(BuildContext todayCtx, String module, int tab) {
    switch (module) {
      case 'প্রজেক্ট':
        Navigator.pop(todayCtx);
        setState(() => _index = 1);
        return;
      case 'ক্যাশবুক':
        Navigator.pop(todayCtx);
        _openCashbook();
        return;
      case 'ভল্ট':
        Navigator.pop(todayCtx);
        _openVault();
        return;
      case 'রিমাইন্ডার':
        Navigator.push(todayCtx,
            MaterialPageRoute(builder: (_) => const ReminderScreen()));
        return;
      case 'চাকরি হাব':
        Navigator.push(
            todayCtx,
            MaterialPageRoute(
                builder: (_) =>
                    JobHubScreen(onOpenVault: _openVault, initialTab: tab)));
        return;
      case 'পরিবার':
        Navigator.push(
            todayCtx,
            MaterialPageRoute(
                builder: (_) =>
                    FamilyHomeScreen(onOpenVault: _openVault, initialTab: tab)));
        return;
      case 'ব্যাকআপ':
        Navigator.push(todayCtx,
            MaterialPageRoute(builder: (_) => const BackupCenterScreen()));
        return;
      case 'ডকুমেন্ট ও তথ্য':
        Navigator.push(todayCtx,
            MaterialPageRoute(builder: (_) => const DocsHomeScreen()));
        return;
      case 'স্ক্রিন টাইম':
        Navigator.push(todayCtx,
            MaterialPageRoute(builder: (_) => const ScreenTimeScreen()));
        return;
    }
  }

  Future<void> _openReminderOrCircular(int? reminderId) async {
    if (reminderId != null) {
      try {
        final circulars = await JobService.circulars();
        for (final c in circulars) {
          if (c.deadlineRem.contains(reminderId) ||
              c.examRem.contains(reminderId)) {
            if (!mounted) return;
            final nav = Navigator.of(context);
            nav.popUntil((r) => r.isFirst);
            await nav.push(MaterialPageRoute(
                builder: (_) => JobHubScreen(
                    onOpenVault: _openVault,
                    initialTab: 2,
                    focusCircularId: c.id,
                    focusCircularAction: 'sheet')));
            return;
          }
        }
      } catch (_) {}
    }
    await _openReminderScreen();
  }

  Future<void> _openReminderScreen() async {
    if (_reminderOpen || !mounted) return;
    _reminderOpen = true;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    await nav.push(MaterialPageRoute(builder: (_) => const ReminderScreen()));
    _reminderOpen = false;
  }

  Future<void> _openIdeaById(int? ideaId) async {
    if (ideaId == null || !mounted) return;
    final idea = await DBHelper.getIdeaById(ideaId);
    if (idea == null || !mounted) return;
    final project = await DBHelper.getProjectById(idea.projectId);
    if (project == null || !mounted) return;
    if (project.isLocked) {
      final ok = await AuthService.authenticate(
          reason: '"${project.name}" লক করা — যাচাই করো');
      if (!ok || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => IdeaDetailScreen(idea: idea, project: project)));
  }

  Future<void> _openProjectById(int? projectId) async {
    if (projectId == null || !mounted) return;
    final project = await DBHelper.getProjectById(projectId);
    if (project == null || !mounted) return;
    if (project.isLocked) {
      final ok = await AuthService.authenticate(
          reason: '"${project.name}" লক করা — যাচাই করো');
      if (!ok || !mounted) return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ProjectDetailScreen(project: project)));
  }

  /// Tapping a reminder notification's body opens the Reminder screen,
  /// অথবা রিমাইন্ডারটা সার্কুলারের হলে সরাসরি সেই সার্কুলার।
  Future<void> _openReminders() async {
    final id = ReminderService.pendingReminderId;
    ReminderService.pendingReminderId = null;
    await _openReminderOrCircular(id);
  }

  /// "Share TO My Manager" — content shared in from other apps (browser,
  /// gallery, WhatsApp, etc.) arrives here, whether the app was already
  /// open or was launched fresh by the share itself.
  void _initShareListener() {
    try {
      // While the app is already running.
      _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) => _handleSharedFiles(files),
        onError: (_) {},
      );
      // Cold start via a share.
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        if (files.isNotEmpty) _handleSharedFiles(files);
      }).catchError((_) {});
    } catch (_) {
      // If the share-intent plugin isn't available for any reason, the
      // rest of the app should still work fine without it.
    }
  }

  void _handleSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShareIntakeScreen(sharedFiles: files),
    )).then((_) => setState(() => _dashboardGen++));
  }

  void _onExternalChange() {
    if (mounted) setState(() => _dashboardGen++);
  }

  @override
  void dispose() {
    DataSync.ideasChanged.removeListener(_onExternalChange);
    DataSync.stop();
    WidgetsBinding.instance.removeObserver(this);
    ReminderService.openRequest.removeListener(_openReminders);
    ReminderService.cashbookOpenRequest.removeListener(_openCashbookFromNotification);
    ReminderService.targetRequest.removeListener(_openPendingTarget);
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      DataSync.stop(); // ব্যাকগ্রাউন্ডে ব্যাটারি বাঁচাতে
    }
    if (state == AppLifecycleState.resumed) {
      DataSync.start();
      DataSync.check();
      SpendingGuard.nudgeIfNeeded().catchError((_) {});
      // জব রাডার: ফোন ব্যাকগ্রাউন্ড টাস্ক চালাতে না দিলেও অ্যাপ খুললেই নতুন সার্কুলার/শেষ তারিখের অ্যালার্ম ঠিক করে নেয়
      RadarRunner.runIfDue().then((_) {}, onError: (_) {});
      setState(() => _dashboardGen++);
      CashbookNotificationService.refresh();
      ReminderService.rearmAll().catchError((_) {});
      NotificationService.scheduleDailyDigest().catchError((_) {});
      ReminderService.changes.value++;
      _checkBubbleTarget();
      _checkLaunchTarget();
    }
    // Refresh the home screen widget whenever the app leaves the
    // foreground — covers ideas added/edited/completed during the
    // session, right before the person goes back to their home screen.
    if (state == AppLifecycleState.paused) {
      WidgetService.update();
    }
  }

  /// Vault isn't one of the swappable IndexedStack tabs — tapping it
  /// authenticates, then pushes it as a full route on top of everything
  /// (same as the auto-lock-on-pause behavior it already has when opened
  /// this way). The bottom nav's selected tab underneath doesn't change,
  /// so returning from the vault lands back exactly where you were.
  Future<void> _openVault() async {
    final canAuth = await AuthService.canAuthenticate();
    if (!canAuth) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar( SnackBar(
        content: Text('ডিভাইসে ফিঙ্গারপ্রিন্ট/PIN সেট করা নেই'),
        backgroundColor: AppTheme.red,
      ));
      return;
    }
    final ok = await AuthService.authenticate(reason: 'ভল্ট খুলতে যাচাই করো');
    if (ok && mounted) {
      // ভল্টের নিজস্ব প্যাটার্ন লক (সেট করা থাকলে) — ফিঙ্গারপ্রিন্টের
      // পরের আলাদা স্তর (ব্যবহারকারীর নির্দেশ ২০২৬-১১-১৭)।
      if (await VaultPatternService.isSet()) {
        final pok = await Navigator.push<bool>(context,
            MaterialPageRoute(builder: (_) => const PatternLockScreen(mode: PatternLockMode.unlock)));
        if (pok != true || !mounted) return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultScreen()));
    }
  }

  /// Authenticator এখন ভল্টের বাইরে, হাতের কাছে (ব্যবহারকারীর
  /// নির্দেশ ২০২৬-১১-১৭) — হোম গ্রিড ও লং-প্রেস শর্টকাট দুই পথই
  /// এখানে আসে। ফিঙ্গারপ্রিন্ট যাচাই লাগে; ডিভাইসে কোনো যাচাই
  /// পদ্ধতিই না থাকলে সরাসরি খোলে (আটকানোর উপায় নেই বলে)।
  Future<void> _openAuthenticator() async {
    final canAuth = await AuthService.canAuthenticate();
    if (canAuth) {
      final ok = await AuthService.authenticate(reason: 'Authenticator খুলতে যাচাই করো');
      if (!ok || !mounted) return;
    }
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const AuthenticatorScreen()));
    }
  }

  bool _cashbookNotifOpen = false;

  /// সন্ধ্যার ক্যাশবুক সতর্কতায় ট্যাপ — সরাসরি ক্যাশবুক খোলে
  /// (লক চালু থাকলে _openCashbook-এর ভেতরেই যাচাই হয়)।
  Future<void> _openCashbookFromNotification() async {
    if (_cashbookNotifOpen || !mounted) return;
    _cashbookNotifOpen = true;
    await _openCashbook();
    _cashbookNotifOpen = false;
  }

  /// Cashbook follows the exact same "authenticate, then push as its own
  /// route" pattern as the Vault above — the lock can be turned off from
  /// inside the Cashbook's own settings if the user doesn't want it.
  Future<void> _openCashbook() async {
    if (!CashbookService.lockEnabled) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const CashbookScreen()));
      return;
    }
    final canAuth = await AuthService.canAuthenticate();
    if (!canAuth) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('ডিভাইসে ফিঙ্গারপ্রিন্ট/PIN সেট করা নেই'),
        backgroundColor: AppTheme.red,
      ));
      return;
    }
    final ok = await AuthService.authenticate(reason: 'ক্যাশবুক খুলতে যাচাই করো');
    if (ok && mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const CashbookScreen()));
    }
  }

  bool _exitAsking = false;

  /// ফোনের নিজস্ব ব্যাক চাপলে (এই শেল সবার নিচের স্ক্রিন, তাই এখানে পৌঁছালে আর কোনো
  /// পুশ-করা স্ক্রিন/ডায়ালগ/শিট খোলা নেই — সেগুলো নিজেরাই আগে বন্ধ হয়ে যায়):
  ///  ১. প্রজেক্ট/খোঁজো/সেটিংস ট্যাবে থাকলে → হোম ট্যাবে ফেরে, অ্যাপ বন্ধ হয় না।
  ///  ২. হোমে থাকলে → "অ্যাপ বন্ধ করবে?" জিজ্ঞেস করে; হ্যাঁ হলেই কেবল বন্ধ।
  Future<void> _onBack() async {
    // বাবলের ভাসমান উইন্ডোতে ব্যাক মানে উইন্ডো লুকানো — "অ্যাপ বন্ধ
    // করবে?" ডায়ালগ নয়, হোম ট্যাবে ফেরাও নয়।
    if (BubbleWindow.isBubble) {
      BubbleWindow.hidePanel();
      return;
    }
    if (_index != 0) {
      setState(() => _index = 0);
      return;
    }
    if (_exitAsking) return;
    _exitAsking = true;
    final exit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: const Text('অ্যাপ বন্ধ করবে?'),
        content: const Text('My Manager থেকে বেরিয়ে যেতে চাও?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('না'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('হ্যাঁ', style: TextStyle(color: AppTheme.red)),
          ),
        ],
      ),
    );
    _exitAsking = false;
    if (exit == true) SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      LifeHomeScreen(
        onOpenProjects: () => setState(() => _index = 1),
        onOpenVault: _openVault,
        onOpenCashbook: _openCashbook,
        onOpenAuthenticator: _openAuthenticator,
        onOpenSettings: () => setState(() => _index = 3),
        onThemeToggle: widget.onThemeToggle,
      ),
      DashboardScreen(key: ValueKey(_dashboardGen), onThemeToggle: widget.onThemeToggle),
      const SearchScreen(),
      SettingsScreen(onThemeToggle: widget.onThemeToggle),
    ];

    return PopScope(
      canPop: false, // ব্যাক চাপলে অ্যাপ নিজে থেকে কেটে যাবে না — _onBack সামলাবে
      onPopInvoked: (didPop) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
      backgroundColor: AppTheme.bg,
      // বাবলের ভেতরে IndexedStack-এর ৪টা ট্যাব একসাথে বানানো ভারী —
      // চালু হতেই সব ট্যাবের DB পড়া + বিল্ড হয়, ফোন স্লো হয়ে যায়।
      // তাই বাবলে শুধু যে ট্যাবটা দেখা যাচ্ছে সেটাই বানানো হয়।
      body: BubbleWindow.isBubble
          ? tabs[_index]
          : IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppTheme.bg2,
          indicatorColor: AppTheme.accent.withOpacity(0.15),
          labelTextStyle: MaterialStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: states.contains(MaterialState.selected)
                  ? AppTheme.accent : AppTheme.textMuted)),
          iconTheme: MaterialStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(MaterialState.selected)
                  ? AppTheme.accent : AppTheme.textMuted)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            if (i == 3) {
              // Vault's position in the destinations list below — a tap
              // here never changes _index, it just opens the vault as
              // its own route.
              _openVault();
              return;
            }
            if (i == 4) {
              // Cashbook, same non-tab treatment as Vault right above it.
              _openCashbook();
              return;
            }
            // Settings shifted from index 2 to index 5 to make room for
            // Home, Vault and Cashbook, so map the NavigationBar's index
            // back to the tabs list (Home=0, Projects=1, Search=2, Settings=3).
            setState(() => _index = i == 5 ? 3 : i);
          },
          height: 60,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'হোম'),
            NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: 'প্রজেক্ট'),
            NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'খোঁজো'),
            NavigationDestination(
                icon: Icon(Icons.lock_outline),
                selectedIcon: Icon(Icons.lock),
                label: 'ভল্ট'),
            NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(Icons.account_balance_wallet),
                label: 'ক্যাশবুক'),
            NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'সেটিংস'),
          ],
        ),
      ),
    ),
    );
  }
}
