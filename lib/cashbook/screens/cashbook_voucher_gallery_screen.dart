import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/cashbook_entry.dart';
import '../services/cashbook_service.dart';
import '../../widgets/app_theme.dart';
import '../../widgets/safe_base64_image.dart';

/// Every entry that has a voucher photo attached, as a tappable grid —
/// useful once there are enough entries that scrolling the main list to
/// find "that one receipt" stops being practical.
class CashbookVoucherGalleryScreen extends StatelessWidget {
  final List<CashbookEntry> entries;
  const CashbookVoucherGalleryScreen({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    final withVouchers = entries.where((e) => e.voucherImage != null).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text('ভাউচার (${withVouchers.length})')),
      body: withVouchers.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('📎', style: TextStyle(fontSize: 34)),
                const SizedBox(height: 8),
                Text('কোনো ভাউচার সংযুক্ত নেই', style: AppTheme.body()),
              ]),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8),
              itemCount: withVouchers.length,
              itemBuilder: (context, i) {
                final e = withVouchers[i];
                return GestureDetector(
                  onTap: () => _openViewer(context, e),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SafeBase64Image(data: e.voucherImage!, fit: BoxFit.cover,
                        fallback: Container(color: AppTheme.bg3,
                            child: Icon(Icons.broken_image_outlined, color: AppTheme.textMuted))),
                  ),
                );
              },
            ),
    );
  }

  void _openViewer(BuildContext context, CashbookEntry e) {
    final cat = CashbookService.categoryById(e.category);
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SafeBase64Image(data: e.voucherImage!, fit: BoxFit.contain,
                fallback: Container(padding: const EdgeInsets.all(24), color: AppTheme.bg3,
                    child: Text('ছবি লোড হয়নি', style: TextStyle(color: AppTheme.textMuted)))),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: AppTheme.bg2, borderRadius: BorderRadius.circular(12)),
            child: Text('${cat.icon} ${e.note} · ${e.date} · ${e.type == 'in' ? '+' : '−'}৳${e.amount.round()}',
                style: AppTheme.body(size: 12.5), textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }
}
