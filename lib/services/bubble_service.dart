import 'package:flutter/services.dart';

/// মূল অ্যাপ থেকে ভাসমান বাবল চালু/বন্ধ করার চ্যানেল।
///
/// নেটিভ দিক: MainActivity-তে `BubbleControl` (Kotlin) এই একই চ্যানেল
/// নামে (`com.hanif.mymanager/bubble`) উত্তর দেয়। প্যানেলের ভেতরের
/// চ্যানেলটা আলাদা (`com.hanif.mymanager/bubble-panel`) — দুটো গুলিয়ে
/// ফেললে চলবে না: এটা মূল অ্যাপের engine-এর, ওটা বাবলের engine-এর।
class BubbleControl {
  static const _channel = MethodChannel('com.hanif.mymanager/bubble');

  static Future<bool> isOverlayGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isOverlayGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// নেটিভে লেখা enabled-ই সত্য — ড্র্যাগ-টু-X দিয়ে বন্ধ করলে Dart-এর
  /// SettingsService-এর মান তখনো true থাকতে পারে।
  static Future<bool> isBubbleEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isBubbleEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isBubbleRunning() async {
    try {
      return await _channel.invokeMethod<bool>('isBubbleRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openOverlaySettings() async {
    try {
      await _channel.invokeMethod<void>('openOverlaySettings');
    } catch (_) {}
  }

  /// বাবল থেকে মূল অ্যাপে আসার সময় সঙ্গে পাঠানো গন্তব্য (যেমন
  /// 'backup') — একবারই পাওয়া যায়, পড়লেই মুছে যায়। না থাকলে null।
  static Future<String?> takeBubbleTarget() async {
    try {
      return await _channel.invokeMethod<String>('takeBubbleTarget');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> startBubble() async {
    try {
      return await _channel.invokeMethod<bool>('startBubble') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopBubble() async {
    try {
      await _channel.invokeMethod<void>('stopBubble');
    } catch (_) {}
  }
}
