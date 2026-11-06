import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';
import '../services/settings_service.dart';
import '../services/bubble_service.dart';
import '../services/notification_service.dart';
import '../services/drive_service.dart';
import '../widgets/app_theme.dart';
import 'package:flutter_autofill_service/flutter_autofill_service.dart';
import 'crash_log_screen.dart';

// Must match the constant of the same name in main.dart — kept as a
// separate literal here (rather than importing main.dart) to avoid a
// circular import (main.dart -> home_shell.dart -> settings_screen.dart).
const _autoBackupTaskName = 'my_manager_auto_backup';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  const SettingsScreen({super.key, required this.onThemeToggle});
  @override State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isDark = SettingsService.isDark;
  String _appVersion = '...';
  bool _bubbleEnabled = SettingsService.getBool('bubble_enabled', defaultValue: false);
  bool _bubbleBusy = false;
  bool _autoBackupEnabled = SettingsService.getBool('auto_backup_enabled', defaultValue: false);
  bool _autoBackupBusy = false;
  bool _digestEnabled = true;
  int _digestHour = 8;
  int _digestMinute = 0;
  bool? _autofillSavingEnabled;
  bool? _autofillIMEEnabled;
  bool _autofillOnlySaved = true;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _loadDigestPrefs();
    _loadAutofillPrefs();
    _syncBubbleState();
  }

  /// APK-এর আসল ভার্সন দেখায় — আগে হাতে লেখা "5.0.0" ছিল, তাই
  /// সেটিংস আর ফোনের App info-তে আলাদা দেখাত।
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {}
  }

  /// নেটিভ enabled-ই সত্য — ড্র্যাগ-টু-X দিয়ে বন্ধ করলে Dart-এর
  /// `bubble_enabled` তখনো true থাকতে পারে; টগলের অবস্থা সেটাই দেখাবে।
  Future<void> _syncBubbleState() async {
    try {
      final nativeEnabled = await BubbleControl.isBubbleEnabled();
      final dartWanted =
          SettingsService.getBool('bubble_enabled', defaultValue: false);
      if (nativeEnabled != dartWanted) {
        await SettingsService.setBool('bubble_enabled', nativeEnabled);
      }
      if (mounted && nativeEnabled != _bubbleEnabled) {
        setState(() => _bubbleEnabled = nativeEnabled);
      }
    } catch (_) {}
  }

  Future<void> _loadAutofillPrefs() async {
    try {
      _autofillOnlySaved = SettingsService.getBool('af_only_saved', defaultValue: true);
    } catch (_) {}
    try {
      final prefs = await AutofillService().preferences;
      if (mounted) setState(() {
        _autofillSavingEnabled = prefs.enableSaving;
        _autofillIMEEnabled = prefs.enableIMERequests;
      });
    } catch (_) {
      // Plugin not ready yet / not supported on this device — the
      // toggles just won't render, same as if autofill weren't set up.
    }
  }

  Future<void> _setAutofillSaving(bool v) async {
    try {
      await AutofillService().setPreferences(AutofillPreferences(
        enableDebug: false, enableSaving: v, enableIMERequests: _autofillIMEEnabled ?? false,
      ));
      setState(() => _autofillSavingEnabled = v);
    } catch (_) {}
  }

  Future<void> _setAutofillIME(bool v) async {
    try {
      await AutofillService().setPreferences(AutofillPreferences(
        enableDebug: false, enableSaving: _autofillSavingEnabled ?? true, enableIMERequests: v,
      ));
      setState(() => _autofillIMEEnabled = v);
    } catch (_) {}
  }

  Future<void> _loadDigestPrefs() async {
    final enabled = SettingsService.getBool('digest_enabled', defaultValue: true);
    final hour = SettingsService.getInt('digest_hour', defaultValue: 8);
    final minute = SettingsService.getInt('digest_minute', defaultValue: 0);
    setState(() { _digestEnabled = enabled; _digestHour = hour; _digestMinute = minute; });
  }

  Future<void> _saveDigestPrefs() async {
    await SettingsService.setBool('digest_enabled', _digestEnabled);
    await SettingsService.setInt('digest_hour', _digestHour);
    await SettingsService.setInt('digest_minute', _digestMinute);
    if (_digestEnabled) {
      await NotificationService.scheduleDailyDigest(
          hour: _digestHour, minute: _digestMinute);
    } else {
      await NotificationService.cancelDailyDigest();
    }
  }

  Future<void> _pickDigestTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _digestHour, minute: _digestMinute),
      builder: (c, child) => Theme(
        data: ThemeData.dark().copyWith(colorScheme:
         ColorScheme.dark(primary: AppTheme.accent, surface: AppTheme.bg3)),
        child: child!,
      ),
    );
    if (t == null) return;
    setState(() { _digestHour = t.hour; _digestMinute = t.minute; });
    await _saveDigestPrefs();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Daily digest ${t.format(context)} এ set হয়েছে ✅'),
      backgroundColor: AppTheme.green,
    ));
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  Future<void> _onBubbleToggle(bool val) async {
    if (_bubbleBusy) return;
    setState(() => _bubbleBusy = true);
    try {
      if (val) {
        // ওভারলে অনুমতির কোনো রানটাইম ডায়ালগ নেই — সেটিংস পাতায়
        // গিয়ে ব্যবহারকারী নিজে "অন্য অ্যাপের ওপরে দেখাও" চালু করেন।
        // তাই অনুমতি না থাকলে পাতা খুলে দিই, আর ফিরে এসে আবার টগল
        // চাপলে চালু হবে — এখানে অনুমতি এসেছে ধরে নেওয়া হয় না।
        final granted = await BubbleControl.isOverlayGranted();
        if (!granted) {
          await BubbleControl.openOverlaySettings();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('সেটিংসে "অন্য অ্যাপের ওপরে দেখাও" চালু করে ফিরে এসে আবার বাবল চালু করো'),
            backgroundColor: AppTheme.red,
          ));
          setState(() => _bubbleBusy = false);
          return;
        }
        final started = await BubbleControl.startBubble();
        if (!started) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('বাবল চালু করা যায়নি — অনুমতি আছে কিনা দেখো'),
            backgroundColor: AppTheme.red,
          ));
          setState(() => _bubbleBusy = false);
          return;
        }
      } else {
        await BubbleControl.stopBubble();
      }
      await SettingsService.setBool('bubble_enabled', val);
      if (mounted) setState(() { _bubbleEnabled = val; _bubbleBusy = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _bubbleBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('বাবল চালু করা যায়নি: $e'),
          backgroundColor: AppTheme.red,
        ));
      }
    }
  }

  Future<void> _onAutoBackupToggle(bool val) async {
    if (_autoBackupBusy) return;
    setState(() => _autoBackupBusy = true);
    try {
      if (val) {
        if (!DriveService.instance.isSignedIn) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar( SnackBar(
            content: Text('আগে Backup পেজ থেকে Google Account সাইন-ইন করো'),
            backgroundColor: AppTheme.red,
          ));
          setState(() => _autoBackupBusy = false);
          return;
        }
        await Workmanager().registerPeriodicTask(
          _autoBackupTaskName, _autoBackupTaskName,
          frequency: const Duration(hours: 1),
          constraints: Constraints(networkType: NetworkType.unmetered),
          existingWorkPolicy: ExistingWorkPolicy.replace,
        );
      } else {
        await Workmanager().cancelByUniqueName(_autoBackupTaskName);
      }
      await SettingsService.setBool('auto_backup_enabled', val);
      if (mounted) setState(() { _autoBackupEnabled = val; _autoBackupBusy = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _autoBackupBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Auto-backup চালু করা যায়নি: $e'),
          backgroundColor: AppTheme.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title:  Text('সেটিংস', style: TextStyle(color: AppTheme.textPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('থিম'),
          _settingTile(
            icon: _isDark ? Icons.dark_mode : Icons.light_mode,
            iconColor: _isDark ? AppTheme.accent : AppTheme.yellow,
            title: _isDark ? 'ডার্ক মোড চালু' : 'লাইট মোড চালু',
            subtitle: 'থিম পরিবর্তন করো',
            trailing: Switch(
              value: _isDark,
              activeColor: AppTheme.accent,
              onChanged: (val) async {
                await SettingsService.setDark(val);
                setState(() => _isDark = val);
                widget.onThemeToggle();
              },
            ),
          ),
          const SizedBox(height: 16),

          _sectionTitle('Quick Access'),
          _settingTile(
            icon: Icons.lightbulb_outline,
            iconColor: AppTheme.accent,
            title: 'ফ্লোটিং বাবল',
            subtitle: 'হোম স্ক্রিন ও অন্য অ্যাপের উপরেও ভাসবে (Messenger-এর মতো) — '
                'বাবলে ট্যাপ করলে প্যানেল খুলবে, আবার ট্যাপ করলে লুকাবে; '
                'নিচের ✕-এ টেনে নিলে বাবল বন্ধ হবে। সিস্টেম পারমিশন লাগবে',
            trailing: _bubbleBusy
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
                : Switch(
                    value: _bubbleEnabled,
                    activeColor: AppTheme.accent,
                    onChanged: _onBubbleToggle,
                  ),
          ),
          const SizedBox(height: 16),

          _sectionTitle('Backup'),
          _settingTile(
            icon: Icons.cloud_sync_outlined,
            iconColor: AppTheme.accent,
            title: 'Auto Backup (শুধু WiFi-তে)',
            subtitle: 'প্রতি ঘণ্টায় WiFi-তে থাকলে নিজে থেকে Google Drive-এ backup হবে — '
                'আগে Backup পেজ থেকে একবার sign-in করা লাগবে',
            trailing: _autoBackupBusy
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
                : Switch(
                    value: _autoBackupEnabled,
                    activeColor: AppTheme.accent,
                    onChanged: _onAutoBackupToggle,
                  ),
          ),
          const SizedBox(height: 16),

          // The Vault itself now lives in its own bottom-nav tab (see
          // home_shell.dart) rather than here — a password manager is a
          // different kind of tool from the rest of this app, so it gets
          // its own first-class section instead of being a Settings
          // sub-item. Autofill setup stays here since it's a one-time
          // system-level toggle, not the vault's content.
          _sectionTitle('Autofill'),
          _settingTile(
            icon: Icons.auto_fix_high,
            iconColor: AppTheme.accent,
            title: 'Autofill চালু করো',
            subtitle: 'অন্য অ্যাপ/ব্রাউজারের লগইন ফর্মে My Manager থেকে পাসওয়ার্ড সাজেস্ট হবে — '
                'Android-এর নিজস্ব সেটিংস পেজ খুলবে',
            trailing: Icon(Icons.chevron_right, color: AppTheme.textMuted),
            onTap: () async {
              try {
                await AutofillService().requestSetAutofillService();
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Autofill সেটিংস খোলা যায়নি: $e'),
                  backgroundColor: AppTheme.red,
                ));
              }
            },
          ),
          const SizedBox(height: 8),
          _settingTile(
            icon: Icons.filter_alt_outlined,
            iconColor: AppTheme.accent,
            title: 'শুধু সেভ করা সাইট/অ্যাপে সাজেশন',
            subtitle: 'যে ওয়েবসাইট/অ্যাপের পাসওয়ার্ড ভল্টে সেভ আছে শুধু সেখানেই Autofill আসবে। '
                'যেখানে সেভ নেই সেখানে কোনো কার্ড বা ফিঙ্গারপ্রিন্ট প্রম্পট আসবে না। '
                'বন্ধ করলে সব জায়গায় পুরো তালিকা দেখাবে।',
            trailing: Switch(
              value: _autofillOnlySaved,
              activeColor: AppTheme.accent,
              onChanged: (v) async {
                setState(() => _autofillOnlySaved = v);
                try { await SettingsService.setBool('af_only_saved', v); } catch (_) {}
              },
            ),
          ),
          if (_autofillSavingEnabled != null) ...[
            const SizedBox(height: 8),
            _settingTile(
              icon: Icons.save_outlined,
              iconColor: AppTheme.accent,
              title: 'নতুন লগইন সেভের প্রম্পট',
              subtitle: 'অন্য অ্যাপে নতুন পাসওয়ার্ড লিখলে ভল্টে সেভ করার প্রস্তাব আসবে',
              trailing: Switch(
                value: _autofillSavingEnabled!,
                activeColor: AppTheme.accent,
                onChanged: _setAutofillSaving,
              ),
            ),
          ],
          if (_autofillIMEEnabled != null) ...[
            const SizedBox(height: 8),
            _settingTile(
              icon: Icons.keyboard_outlined,
              iconColor: AppTheme.accent,
              title: 'কিবোর্ডে ইনলাইন সাজেশন',
              subtitle: 'Android 12+ এ কিবোর্ডের উপরেই পাসওয়ার্ড সাজেশন দেখাবে (এক্সপেরিমেন্টাল)',
              trailing: Switch(
                value: _autofillIMEEnabled!,
                activeColor: AppTheme.accent,
                onChanged: _setAutofillIME,
              ),
            ),
          ],
          const SizedBox(height: 16),

          _sectionTitle('Daily Digest Notification'),
          _settingTile(
            icon: Icons.notifications_outlined,
            iconColor: AppTheme.accent,
            title: 'Daily Digest',
            subtitle: 'প্রতিদিন সকালে pending task এর সারসংক্ষেপ',
            trailing: Switch(
              value: _digestEnabled,
              activeColor: AppTheme.accent,
              onChanged: (val) async {
                setState(() => _digestEnabled = val);
                await _saveDigestPrefs();
              },
            ),
          ),
          if (_digestEnabled)
            _settingTile(
              icon: Icons.access_time_outlined,
              iconColor: AppTheme.green,
              title: 'Digest সময়',
              subtitle: 'প্রতিদিন ${_pad(_digestHour)}:${_pad(_digestMinute)} তে notification আসবে',
              trailing: GestureDetector(
                onTap: _pickDigestTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.accent.withOpacity(0.5)),
                  ),
                  child: Text('${_pad(_digestHour)}:${_pad(_digestMinute)}',
                      style: const TextStyle(color: AppTheme.accent,
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
            ),
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.bg2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
               Row(children: [
                Icon(Icons.info_outline, color: AppTheme.textMuted, size: 14),
                SizedBox(width: 6),
                Text('Digest এ কী থাকবে:', style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 6),
              ...['📋 মোট pending task সংখ্যা',
                '📅 আজকে ও কালকের deadline',
                '⚠️ Overdue task এর সংখ্যা'].map((s) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $s', style:  TextStyle(
                    color: AppTheme.textMuted, fontSize: 12)),
              )),
            ]),
          ),

          const SizedBox(height: 16),
          _sectionTitle('অ্যাপ তথ্য'),
          _settingTile(
            icon: Icons.rocket_launch_outlined, iconColor: AppTheme.accent,
            title: 'My Manager', subtitle: 'Version $_appVersion',
          ),
          _settingTile(
            icon: Icons.code, iconColor: AppTheme.textSecondary,
            title: 'Package', subtitle: 'com.hanif.mymanager',
          ),
          _settingTile(
            icon: Icons.storage_outlined, iconColor: AppTheme.green,
            title: 'Storage', subtitle: 'SQLite Local Database (v5)',
          ),

          const SizedBox(height: 16),
          _sectionTitle('ডিবাগ'),
          _settingTile(
            icon: Icons.bug_report_outlined, iconColor: AppTheme.red,
            title: 'ক্র্যাশ লগ', subtitle: 'অ্যাপ ক্র্যাশ করলে বিস্তারিত এখানে জমা থাকে — কপি করা যায়',
            trailing: Icon(Icons.chevron_right, color: AppTheme.textMuted),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CrashLogScreen())),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(), style:  TextStyle(
        color: AppTheme.textMuted, fontSize: 11,
        fontWeight: FontWeight.w700, letterSpacing: 1)),
  );

  Widget _settingTile({required IconData icon, required Color iconColor,
      required String title, String? subtitle, Widget? trailing, VoidCallback? onTap}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: AppTheme.bg2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: ListTile(
          onTap: onTap,
          leading: Container(width: 36, height: 36,
            decoration: BoxDecoration(color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: iconColor, size: 18)),
          title: Text(title, style:  TextStyle(
              color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: subtitle != null ? Text(subtitle,
              style:  TextStyle(color: AppTheme.textMuted, fontSize: 12)) : null,
          trailing: trailing,
        ),
      );
}
