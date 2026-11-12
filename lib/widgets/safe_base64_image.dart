import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// base64 ছবি দেখানোর নিরাপদ উইজেট। সরাসরি `Image.memory(base64Decode(...))`
/// build-এর ভেতরে ডাকলে নষ্ট base64-এ FormatException ছোড়ে — যেটা
/// Image-এর errorBuilder ধরতে পারে না, ফলে পুরো স্ক্রিন ক্র্যাশ করে।
/// এখানে decode আগেই try/catch-এ হয়; ব্যর্থ হলে [fallback] দেখায়।
class SafeBase64Image extends StatelessWidget {
  final String data;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget fallback;

  const SafeBase64Image({
    super.key,
    required this.data,
    this.width,
    this.height,
    this.fit,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      bytes = null;
    }
    if (bytes == null) return fallback;
    return Image.memory(
      bytes,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => fallback,
    );
  }
}
