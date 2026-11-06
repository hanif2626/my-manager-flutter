import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/bubble_picker.dart';
import '../services/docs_service.dart';
import 'docs_home_screen.dart';

/// ক্যামেরা / গ্যালারি / ফাইল থেকে পাতা বাছাই। বাইরের স্ক্রিন খোলার সময় ভল্টের
/// অটো-লক সাময়িক বন্ধ থাকে, নইলে ফেরার আগেই স্ক্রিন বন্ধ হয়ে যেত।
class DocsPicker {
  static const maxBytes = 15 * 1024 * 1024;

  static String _mimeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  static Future<T> _guard<T>(Future<T> Function() f) async {
    DocsHomeScreen.suppressAutoLock = true;
    try {
      return await f();
    } finally {
      DocsHomeScreen.suppressAutoLock = false;
    }
  }

  /// null → বাতিল। বড় ফাইলে FormatException।
  static Future<NewDocPage?> image(ImageSource source) => _guard(() async {
        final img = await BubblePicker.pickImage(source: source, imageQuality: 85, maxWidth: 2200);
        if (img == null) return null;
        final bytes = await img.readAsBytes();
        if (bytes.length > maxBytes) throw const FormatException('ফাইল ১৫ MB-এর বেশি');
        return NewDocPage(bytes, img.name, _mimeOf(img.name));
      });

  /// গ্যালারি থেকে একসাথে অনেক ছবি (পাতার সংখ্যা ঠিক না থাকা ডকুমেন্টের জন্য)।
  static Future<List<NewDocPage>> manyImages() => _guard(() async {
        final list = await BubblePicker.pickMultiImage(imageQuality: 85, maxWidth: 2200);
        final out = <NewDocPage>[];
        for (final img in list) {
          final bytes = await img.readAsBytes();
          if (bytes.length > maxBytes) throw const FormatException('একটা ছবি ১৫ MB-এর বেশি');
          out.add(NewDocPage(bytes, img.name, _mimeOf(img.name)));
        }
        return out;
      });

  static Future<NewDocPage?> file() => _guard(() async {
        final r = await BubblePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
          withData: true,
        );
        if (r == null || r.files.isEmpty) return null;
        final f = r.files.first;
        final bytes = f.bytes;
        if (bytes == null) throw const FormatException('ফাইলটা পড়া যায়নি');
        if (bytes.length > maxBytes) throw const FormatException('ফাইল ১৫ MB-এর বেশি');
        return NewDocPage(bytes, f.name, _mimeOf(f.name));
      });
}
