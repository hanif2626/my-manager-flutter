import 'package:flutter/services.dart';

/// বাবলের ভাসমান উইন্ডোর ভেতরে চলছে কি না — মূল অ্যাপের main() নয়,
/// bubbleMain() এটা true করে দেয়। Activity-নির্ভর কাজ (বায়োমেট্রিক,
/// ছবি/ফাইল বাছা, Google Sign-In) বাবলের উইন্ডোতে সরাসরি চলে না —
/// সেগুলো মূল অ্যাপে খুলে করতে হয় (ব্যবহারকারীর সিদ্ধান্ত)।
class BubbleWindow {
  static bool isBubble = false;

  static const _channel = MethodChannel('com.hanif.mymanager/bubble-panel');

  /// মূল অ্যাপ (MainActivity) খোলে — বাবলের উইন্ডো লুকিয়ে যায়।
  /// [target] দিলে মূল অ্যাপ সেই পেজেই খুলবে (যেমন 'backup' —
  /// সাইন-ইনের জন্য), পুরনো অবস্থার পেজে নয়।
  static Future<void> openMainApp({String? target}) async {
    try {
      await _channel.invokeMethod('openApp', {'target': target});
    } catch (_) {}
  }

  /// ভাসমান উইন্ডো লুকায় — ডট থাকে।
  static Future<void> hidePanel() async {
    try {
      await _channel.invokeMethod('hidePanel');
    } catch (_) {}
  }
}
