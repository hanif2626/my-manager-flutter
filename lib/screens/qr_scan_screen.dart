import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen QR scanner. Pops with the first scanned value (String),
/// or null when the user backs out.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});
  @override State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.pop(context, v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('QR কোড স্ক্যান করো'),
      ),
      body: Stack(children: [
        MobileScanner(onDetect: _onDetect),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Authenticator-এর QR কোডটা ক্যামেরার সামনে ধরো',
              style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13.5),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ]),
    );
  }
}
