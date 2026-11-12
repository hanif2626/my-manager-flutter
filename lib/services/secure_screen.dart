import 'package:flutter/services.dart';

/// সংবেদনশীল স্ক্রিনে (ভল্ট, ডকস, অটোফিল পিকার) স্ক্রিনশট ও
/// টাস্ক-সুইচার থাম্বনেইলে সিক্রেট দেখা আটকায় (FLAG_SECURE)।
/// স্ক্রিন খুললে [on], বন্ধ হলে [off] ডাকতে হয়। ভেতরে কাউন্টার
/// আছে — একাধিক সংবেদনশীল স্ক্রিন একসাথে খোলা থাকলে শেষটা বন্ধ
/// হলেই কেবল ফ্ল্যাগ ওঠে।
class SecureScreen {
  static const _ch = MethodChannel('com.hanif.mymanager/window');
  static int _count = 0;

  static Future<void> on() async {
    _count++;
    if (_count == 1) {
      try {
        await _ch.invokeMethod('setSecure', true);
      } catch (_) {}
    }
  }

  static Future<void> off() async {
    if (_count > 0) _count--;
    if (_count == 0) {
      try {
        await _ch.invokeMethod('setSecure', false);
      } catch (_) {}
    }
  }
}
