import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../widgets/app_theme.dart';
import '../services/docs_service.dart';
import 'docs_picker.dart';

class Captured {
  final String label;
  final NewDocPage page;
  Captured(this.label, this.page);
}

/// ক্যামেরা / গ্যালারির ধাপে ধাপে ছবি নেওয়া।
///  • [labels] দিলে (যেমন সামনের দিক, পেছনের দিক) প্রতিটার জন্য আলাদা ধাপ — "ধাপ ১/২:
///    সামনের দিক" বলে ছবি নেয়; এক পাতার হলে সরাসরি ১টাই।
///  • [labels] না দিলে (পাতার সংখ্যা ঠিক নেই): ক্যামেরায় "আরেকটা তুলবে?" জিজ্ঞেস করে
///    চলতে থাকে; গ্যালারিতে একসাথে অনেক ছবি বাছা যায়।
/// মাঝপথে বাতিল করলে যতটা নেওয়া হয়েছে ততটাই ফেরত দেয়।
class DocCaptureFlow {
  static Future<List<Captured>> run(
    BuildContext context,
    ImageSource source, {
    List<String>? labels,
    int startNumber = 1,
    bool skipPrompts = false,
  }) async {
    final out = <Captured>[];
    try {
      if (labels != null) {
        for (var i = 0; i < labels.length; i++) {
          if (labels.length > 1 && !skipPrompts) {
            if (!context.mounted) break;
            final go = await _prompt(context, source, labels[i], i + 1, labels.length);
            if (!go) break;
          }
          final pg = await DocsPicker.image(source);
          if (pg == null) break;
          out.add(Captured(labels[i], pg));
        }
        return out;
      }

      // পাতার সংখ্যা ঠিক নেই
      var n = startNumber;
      if (source == ImageSource.gallery) {
        final list = await DocsPicker.manyImages();
        for (final pg in list) {
          out.add(Captured('পাতা ${bn(n++)}', pg));
        }
        return out;
      }
      while (true) {
        final pg = await DocsPicker.image(source);
        if (pg == null) break;
        out.add(Captured('পাতা ${bn(n++)}', pg));
        if (!context.mounted) break;
        if (!await _more(context, out.length)) break;
      }
      return out;
    } on FormatException catch (e) {
      if (context.mounted) _snack(context, e.message);
      return out;
    } catch (e) {
      if (context.mounted) _snack(context, 'ছবি নেওয়া যায়নি: $e');
      return out;
    }
  }

  static void _snack(BuildContext c, String m) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

  static Future<bool> _prompt(BuildContext c, ImageSource s, String label, int i, int n) async {
    final cam = s == ImageSource.camera;
    final r = await showDialog<bool>(
      context: c,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('ধাপ ${bn(i)}/${bn(n)}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            cam
                ? '$label-এর ছবি তোলো। পুরো ডকুমেন্ট ফ্রেমে রাখো, আলো ঠিক রাখো, যেন ঝাপসা না হয়।'
                : '$label-এর ছবিটা গ্যালারি থেকে বেছে নাও।',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13.5, height: 1.45),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাদ দাও')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
            onPressed: () => Navigator.pop(ctx, true),
            icon: Icon(cam ? Icons.photo_camera_outlined : Icons.photo_library_outlined, size: 18),
            label: Text(cam ? 'ক্যামেরা খোলো' : 'গ্যালারি খোলো'),
          ),
        ],
      ),
    );
    return r == true;
  }

  static Future<bool> _more(BuildContext c, int count) async {
    final r = await showDialog<bool>(
      context: c,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('${bn(count)}টা পাতা নেওয়া হয়েছে'),
        content: const Text('আরেকটা পাতা তুলবে?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('শেষ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('আরেকটা তোলো'),
          ),
        ],
      ),
    );
    return r == true;
  }
}
