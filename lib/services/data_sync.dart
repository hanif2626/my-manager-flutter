import 'dart:async';
import 'package:flutter/foundation.dart';
import '../db/db_helper.dart';

/// অন্য Flutter engine (ভাসমান বাবলের প্যানেল) থেকে হওয়া ডাটা-পরিবর্তন
/// মূল অ্যাপের স্ক্রিনে পৌঁছে দেয়।
///
/// বাবলের engine থেকে বার্তা পাঠানোর উপর ভরসা করা হয় না — বাবল অ্যাপের
/// উপরে ভাসলে অ্যাপ "resume"ও হয় না। তাই: অ্যাপ সামনে থাকলে প্রতি ২
/// সেকেন্ডে একটা সস্তা কোয়েরি, ছাপ বদলালে [ideasChanged] বাড়ে — যে
/// স্ক্রিন আইডিয়া দেখায় সে শুনে নিজে রিলোড করে।
class DataSync {
  static final ValueNotifier<int> ideasChanged = ValueNotifier(0);
  static Timer? _timer;
  static String? _last;
  static bool _busy = false;

  /// আইডিয়ার পরিবর্তন ঘটেছে কিনা এখনই যাচাই (বাবলের বার্তা বা অ্যাপ resume হলে ডাকা হয়)।
  static Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      final sig = await DBHelper.ideasSignature();
      if (_last != null && sig != _last) ideasChanged.value++;
      _last = sig;
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  static void start() {
    if (_timer != null) return;
    check();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => check());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
