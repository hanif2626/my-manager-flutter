import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../widgets/app_theme.dart';
import '../db/cashbook_db.dart';
import '../services/cashbook_backup_service.dart';
import '../services/cashbook_notification_service.dart';
import '../services/spending_guard.dart';
import '../services/cashbook_widget_service.dart';
import 'cashbook_entry_sheet.dart';

/// হোম-স্ক্রিন উইজেটের "＋ জমা / − খরচ" বাটন থেকে খোলে (CashbookQuickAddActivity)।
/// স্বচ্ছ উইন্ডোর উপর সরাসরি ক্যাশবুকের এন্ট্রি-শিট; সেভ বা বাইরে ট্যাপে বন্ধ।
///
/// নিরাপত্তা: শুধু নতুন এন্ট্রি যোগ হয়, কিছু দেখানো হয় না — তাই ক্যাশবুকের
/// লক/ফিঙ্গারপ্রিন্ট এখানে চাওয়া হয় না।
Future<void> runCashbookQuickAdd() async {
  String type = 'out';
  try {
    type = await const MethodChannel('com.hanif.mymanager/quickadd')
            .invokeMethod<String>('initialType') ??
        'out';
  } catch (_) {}
  int? accountId;
  try {
    accountId = (await CashbookDB.currentMonthAccount()).id;
  } catch (_) {}
  runApp(CashbookQuickAddApp(type: type == 'in' ? 'in' : 'out', accountId: accountId));
}

class CashbookQuickAddApp extends StatelessWidget {
  final String type;
  final int? accountId;
  const CashbookQuickAddApp({super.key, required this.type, required this.accountId});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: _Launcher(type: type, accountId: accountId),
    );
  }
}

class _Launcher extends StatefulWidget {
  final String type;
  final int? accountId;
  const _Launcher({required this.type, required this.accountId});
  @override State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final id = widget.accountId;
    if (id == null) {
      SystemNavigator.pop();
      return;
    }
    try {
      final saved = await CashbookEntrySheet.show(context, accountId: id, initialType: widget.type);
      // সেভ হোক বা না হোক, উইজেটের সংখ্যা হালনাগাদ করে তারপর বন্ধ।
      await CashbookWidgetService.refresh();
      // উইজেট থেকে সেভ হলে ড্রাইভ ব্যাকআপও যাক (আগে এই পথে কখনো ব্যাকআপ হতো না)।
      // বন্ধ করার আগে আপলোড শেষ হওয়া পর্যন্ত অপেক্ষা, তবে সর্বোচ্চ ২০ সেকেন্ড।
      if (saved == true) {
        // কিস্তি/আবশ্যিক খরচের ৩ বেলার সতর্কতা নতুন ব্যালেন্সে আবার বসাই (এই আলাদা engine-এ লিসেনার নেই)।
        try { await SpendingGuard.rearmSlots(); } catch (_) {}
        // সন্ধ্যার আবশ্যিক সতর্কতাও হালনাগাদ করো — এন্ট্রি হয়ে গেলে লেগে-থাকা সতর্কতা উঠে যাবে।
        try { await CashbookNotificationService.refresh(); } catch (_) {}
        await CashbookBackupService.backupSilently().timeout(const Duration(seconds: 20), onTimeout: () {});
      }
    } catch (_) {}
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // স্বচ্ছ — উইজেটের পেছনের হোম স্ক্রিনই দেখা যায়।
    return const Scaffold(backgroundColor: Colors.transparent);
  }
}
