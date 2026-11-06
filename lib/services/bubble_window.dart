import 'package:flutter/services.dart';

/// বাবলের ভাসমান উইন্ডোর ভেতরে চলছে কি না — মূল অ্যাপের main() নয়,
/// bubbleMain() এটা true করে দেয়। Activity-নির্ভর কাজ (বায়োমেট্রিক,
/// ছবি/ফাইল বাছা, Google Sign-In) বাবলের উইন্ডোতে সরাসরি চলে না —
/// সেগুলো মূল অ্যাপে খুলে করতে হয় (ব্যবহারকারীর সিদ্ধান্ত)।
class BubbleWindow {
  static bool isBubble = false;

  static const _channel = MethodChannel('com.hanif.mymanager/bubble-panel');

  /// মূল অ্যাপ (MainActivity) খোলে — বাবলের উইন্ডো লুকিয়ে যায়।
  static Future<void> openMainApp() async {
    try {
      await _channel.invokeMethod('openApp');
    } catch (_) {}
  }

  /// ভাসমান উইন্ডো লুকায় — ডট থাকে।
  static Future<void> hidePanel() async {
    try {
      await _channel.invokeMethod('hidePanel');
    } catch (_) {}
  }
}
