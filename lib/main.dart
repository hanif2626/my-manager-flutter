import 'docs/screens/vault_picker_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:workmanager/workmanager.dart';
import 'services/widget_service.dart';
import 'screens/home_shell.dart';
import 'widgets/app_theme.dart';
import 'services/bubble_window.dart';
import 'services/bubble_service.dart';
import 'screens/autofill_picker_screen.dart';
import 'services/vault_service.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';
import 'services/drive_service.dart';
import 'services/auto_backup.dart';
import 'cashbook/services/cashbook_notification_service.dart';
import 'cashbook/services/cashbook_widget_service.dart';
import 'cashbook/services/spending_guard.dart';
import 'screentime/screen_time_service.dart';
import 'cashbook/screens/cashbook_quick_add_app.dart';
import 'reminder/services/reminder_service.dart';
import 'jobs/radar/radar_runner.dart';

const autoBackupTaskName = 'my_manager_auto_backup';
const cashbookReminderTaskName = 'cashbook_reminder_check';
const reminderRearmTaskName = 'reminder_rearm';
const radarDailyTaskName = 'job_radar_daily';

/// Flutter's default release-mode error widget is a blank grey box with
/// no text (by design, to avoid leaking stack traces to end users) —
/// which is indistinguishable from a genuinely blank screen. Showing the
/// real message here instead makes any future crash immediately
/// diagnosable from a screenshot, on a real device, without adb.
/// main() আর bubbleMain() — দুজনেই এটা ব্যবহার করে।
void _installErrorWidget() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text(
            'কিছু একটা ভুল হয়েছে:\n\n${details.exceptionAsString()}\n\n${details.stack}',
            style: const TextStyle(color: Colors.red, fontSize: 11),
          ),
        ),
      ),
    );
  };
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorWidget();
  try {
    tz.initializeTimeZones();
  } catch (_) {}
  try {
    await SettingsService.init();
  } catch (_) {}
  // হোম-স্ক্রিন ক্যাশবুক উইজেট হালনাগাদ (নতুন মাসের খাতাও এখানে বানানো হয়)।
  CashbookWidgetService.refresh();
  SpendingGuard.nudgeIfNeeded(); // কিস্তি/আবশ্যিক খরচ বাকি থাকলে প্রতিদিন ৩ বেলার সতর্কতা বসায়
  // স্ক্রিন টাইমের সতর্কবার্তার কনফিগ (অনুমতি না থাকলে চুপচাপ কিছু করে না)
  ScreenTimeService.syncConfig();
  // Drive-এ আগে সাইন-ইন করা থাকলে অ্যাপ খোলার সাথেই চুপচাপ ফিরিয়ে আনি, নইলে
  // ক্যাশবুকসহ সব সাইলেন্ট ব্যাকআপ "সাইন-ইন নেই" ভেবে বাদ পড়ত। ব্যর্থ হলে কিছু হয় না।
  DriveService.instance.signInSilently().catchError((_) => false);
  // Autofill ছাঁকনির জন্য সেভ-করা-সাইটের তালিকা (পাসওয়ার্ড ছাড়া) হালনাগাদ।
  VaultService.publishAutofillIndex().catchError((_) {});
  try {
    await NotificationService.init();
    // সকালের "আজকের ম্যানেজার" নোটিফিকেশন (সময়/চালু-বন্ধ সেটিংস থেকে)
    await NotificationService.scheduleDailyDigest();
  } catch (_) {
    // Notifications failing to set up shouldn't block the app either.
  }
  // Reminder module: (re)arm the next few days of alarms for every saved
  // reminder. Cheap and idempotent — also runs on resume and every 6h.
  try {
    await ReminderService.rearmAll();
  } catch (_) {}
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  // বাবল চালু থাকলে অ্যাপ খুললেই ফিরিয়ে আনা — নেটিভে লেখা enabled-ই
  // সত্য (ড্র্যাগ-টু-X দিয়ে বন্ধ করলে Dart-এর মান তখনো true থাকতে
  // পারে)। অনুমতি না থাকলে কিছুই হয় না। try-catch যাতে বাবলের
  // সমস্যা অ্যাপ চালু হতে কখনো বাধা দিতে না পারে।
  try {
    final dartWanted =
        SettingsService.getBool('bubble_enabled', defaultValue: false);
    final nativeEnabled = await BubbleControl.isBubbleEnabled();
    if (nativeEnabled != dartWanted) {
      await SettingsService.setBool('bubble_enabled', nativeEnabled);
    }
    if (nativeEnabled && await BubbleControl.isOverlayGranted()) {
      await BubbleControl.startBubble();
    }
  } catch (_) {
    // Never let a bubble-restore failure prevent the app from starting.
  }
  // Auto-backup on WiFi — opt-in, off by default. If the person turned
  // it on in Settings, make sure the periodic task is (re-)registered
  // every time the app starts, in case it was somehow lost (e.g. after
  // a device reboot on some Android versions).
  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    if (SettingsService.getBool('auto_backup_enabled', defaultValue: false)) {
      await Workmanager().registerPeriodicTask(
        autoBackupTaskName, autoBackupTaskName,
        frequency: const Duration(hours: 1),
        constraints: Constraints(networkType: NetworkType.unmetered),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
    }
  } catch (_) {
    // Auto-backup setup failing shouldn't block the app from starting.
  }
  // Cashbook's "নাগ every 30 minutes after 8pm until an entry exists
  // today" reminder — always on, no setting to disable it, registered
  // once and left running by WorkManager's own dedup (existingWorkPolicy
  // keep). The exact 8pm ping itself is a separate one-off alarm
  // (CashbookNotificationService.refresh, scheduled whenever the
  // Cashbook screen or the app is opened); this periodic task is what
  // keeps nagging afterward even if the app is never reopened that
  // evening.
  try {
    await Workmanager().registerPeriodicTask(
      cashbookReminderTaskName, cashbookReminderTaskName,
      frequency: const Duration(minutes: 30),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  } catch (_) {
    // Reminder scheduling failing shouldn't block the app from starting.
  }
  try {
    await Workmanager().registerPeriodicTask(
      reminderRearmTaskName, reminderRearmTaskName,
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  } catch (_) {}
  // Job Radar: ঘণ্টায় একবার "আজকের রিপোর্টের সময় হয়েছে কি?" দেখে; সময় হলে একবার সার্চ করে
  // রাতে একটাই নোটিফিকেশন দেয় (দিনে বারবার খোঁজে না, বারবার জানায় না)।
  try {
    await Workmanager().registerPeriodicTask(
      radarDailyTaskName, radarDailyTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  } catch (_) {}
  runApp(const MyManagerApp());
  // অ্যাপ খুললেও: আজকের রাতের রিপোর্টের সময় পেরিয়ে থাকলে ও বাকি থাকলে এখনই করে দেয়।
  RadarRunner.runIfDue().then((_) {}, onError: (_) {});
  // অটো-ব্যাকআপের catch-up: শেষ রান ১২ ঘণ্টার বেশি পুরনো হলে এখনই।
  AutoBackup.runIfDue().then((_) {}, onError: (_) {});
  // Refresh the home screen widget on every cold start too, in case
  // something changed while the app wasn't running.
  WidgetService.update();
}

/// Runs in a headless background isolate whenever Android's WorkManager
/// decides conditions are met (WiFi connected, roughly every ~1h — exact
/// timing isn't guaranteed by Android, that's normal WorkManager
/// behavior). Only does anything if the person is already signed in to
/// Google Drive from a previous manual backup — this can't pop up a
/// sign-in screen since there's no UI here.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (task == reminderRearmTaskName) {
        await ReminderService.rearmAll();
        // সকালের ডাইজেস্টের বিষয়বস্তু তাজা রাখো (প্রতি ৬ ঘণ্টায়)।
        try {
          await SettingsService.init();
          await NotificationService.scheduleDailyDigest();
        } catch (_) {}
        // জব রাডারের রিপোর্ট ও শেষ তারিখের অ্যালার্মও (নেটওয়ার্ক লাগে না) — রাডারের নিজের টাস্ক না চললেও বসে থাকে
        try {
          await SettingsService.init();
          await RadarRunner.rearmDaily();
        } catch (_) {}
        return true;
      }
      if (task == radarDailyTaskName) {
        try {
          await SettingsService.init();
          await RadarRunner.runFromBackground();
        } catch (_) {}
        return true;
      }
      if (task == cashbookReminderTaskName) {
        await CashbookNotificationService.backgroundCheck();
        // খরচ-প্রহরীর বারবার-নোটিফিকেশন (সতর্ক অবস্থায়, নির্দিষ্ট ব্যবধানে)
        try {
          await SettingsService.init();
          await SpendingGuard.nudgeIfNeeded();
        } catch (_) {}
        return true;
      }
      await SettingsService.init();
      if (!SettingsService.getBool('auto_backup_enabled', defaultValue: false)) {
        return true;
      }
      await AutoBackup.runAll();
    } catch (_) {
      // Swallow errors — a failed background backup shouldn't crash
      // anything or retry-loop aggressively. It'll just try again on
      // the next scheduled run.
    }
    return true;
  });
}

/// Entry point for the floating bubble window (Messenger-এর চ্যাট
/// উইন্ডোর মতো)। BubbleService-এর নিজের Flutter engine-এ চলে — তবে
/// এখন ভেতরে ছোট প্যানেল নয়, পুরো অ্যাপটাই চলে (MyManagerApp)।
/// main()-এর ব্যাকগ্রাউন্ড কাজ (WorkManager, নোটিফিকেশন ডাইজেস্ট,
/// ড্রাইভ ব্যাকআপ, রিমাইন্ডার rearm) এখানে চালানো হয় না — সেগুলো
/// মূল অ্যাপের কাজ, বাবলে চালালে দুবার চলবে। শুধু UI-এর জন্য
/// দরকারি init-টুকুই এখানে হয়।
@pragma('vm:entry-point')
void bubbleMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorWidget();
  try {
    tz.initializeTimeZones();
  } catch (_) {}
  // SettingsService isn't shared automatically between the app's engine
  // and this separate bubble engine — each needs its own init call.
  try {
    await SettingsService.init();
  } catch (_) {}
  // বাবলের ভাসমান উইন্ডোর ভেতরে চলছে — Activity-নির্ভর কাজ
  // (বায়োমেট্রিক, ছবি/ফাইল বাছা, Google Sign-In) এখানে সরাসরি
  // চলে না; সেগুলো মূল অ্যাপে খুলে করতে হয়।
  BubbleWindow.isBubble = true;
  runApp(const BubbleWindowApp());
}

/// বাবলের ভাসমান উইন্ডোতে পুরো অ্যাপ — Messenger-এর চ্যাট উইন্ডোর মতো।
/// মূল অ্যাপটাই (MyManagerApp), শুধু গোল কোণা আর হালকা বর্ডার।
class BubbleWindowApp extends StatelessWidget {
  const BubbleWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withOpacity(0.15)),
        borderRadius: BorderRadius.circular(28),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: const MyManagerApp(),
      ),
    );
  }
}

/// বাবলের উইন্ডোতে ব্যাক বাটন: ভেতরের পাতা থাকলে সেটা বন্ধ হয়,
/// একদম গোড়ায় থাকলে উইন্ডোটা লুকিয়ে যায় (অ্যাপ বন্ধ হয় না)।
/// মূল অ্যাপে এটা কিছু করে না।
class _BubbleBackHandler extends StatelessWidget {
  const _BubbleBackHandler({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!BubbleWindow.isBubble) return child;
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) BubbleWindow.hidePanel();
      },
      child: child,
    );
  }
}

/// Entry point Android launches when it wants us to show autofill
/// suggestions for a login field somewhere else on the device. Runs in
/// its own separate Flutter engine, same pattern as bubbleMain() above.
@pragma('vm:entry-point')
void autofillEntryPoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SettingsService.init();
  } catch (_) {}
  runApp(const AutofillPickerApp());
}

/// ফাইল-পিকারে "ডকুমেন্ট ভল্ট" চাপলে খোলা স্ক্রিন (VaultPickActivity): যাচাইয়ের পর
/// ভল্ট থেকে ফাইল বেছে আপলোড-ট্রেতে রাখে। নিজের আলাদা Flutter engine-এ চলে।
@pragma('vm:entry-point')
void vaultPickEntryPoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SettingsService.init();
  } catch (_) {}
  runApp(const VaultPickerApp());
}

/// ক্যাশবুক হোম-উইজেটের "＋ জমা / − খরচ" থেকে খোলা দ্রুত-এন্ট্রি শিট
/// (CashbookQuickAddActivity)। নিজের আলাদা Flutter engine-এ চলে।
@pragma('vm:entry-point')
void cashbookQuickAddEntryPoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SettingsService.init();
  } catch (_) {}
  await runCashbookQuickAdd();
}

class MyManagerApp extends StatefulWidget {
  const MyManagerApp({super.key});
  static final navigatorKey = GlobalKey<NavigatorState>();
  static _MyManagerAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_MyManagerAppState>();
  @override State<MyManagerApp> createState() => _MyManagerAppState();
}

class _MyManagerAppState extends State<MyManagerApp> {
  bool _isDark = true;

  @override
  void initState() {
    super.initState();
    _isDark = SettingsService.isDark;
    // Crash log (if any) is now viewed on demand from Settings, not
    // auto-popped-up here — a crash severe/early enough can happen
    // before this widget ever gets a first frame, so a settings-page
    // viewer is the more reliable place either way.
  }

  void toggleTheme() => setState(() => _isDark = SettingsService.isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: MyManagerApp.navigatorKey,
      title: 'My Manager',
      debugShowCheckedModeBanner: false,
      theme: _isDark ? AppTheme.dark : AppTheme.light,
      // Makes any text in the app long-press/drag-selectable and copyable,
      // without having to switch every Text widget to SelectableText.
      builder: (context, child) => SelectionArea(child: child!),
      home: _BubbleBackHandler(child: HomeShell(onThemeToggle: toggleTheme)),
    );
  }
}
