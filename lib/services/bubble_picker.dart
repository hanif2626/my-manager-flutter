import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'bubble_window.dart';

/// ছবি/ফাইল বাছা — বাবলের ভাসমান উইন্ডোতে সরাসরি চলে না (Activity লাগে)।
/// বাবলে থাকলে মূল অ্যাপ খুলে দেয় আর null/খালি ফেরত দেয়; মূল অ্যাপে
/// থাকলে আগের মতোই পিকার খোলে।
class BubblePicker {
  static Future<XFile?> pickImage({
    required ImageSource source,
    int imageQuality = 85,
    double? maxWidth,
  }) async {
    if (BubbleWindow.isBubble) {
      await BubbleWindow.openMainApp();
      return null;
    }
    return ImagePicker().pickImage(
      source: source,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
    );
  }

  static Future<List<XFile>> pickMultiImage({
    int imageQuality = 85,
    double? maxWidth,
  }) async {
    if (BubbleWindow.isBubble) {
      await BubbleWindow.openMainApp();
      return const [];
    }
    return ImagePicker().pickMultiImage(
      imageQuality: imageQuality,
      maxWidth: maxWidth,
    );
  }

  static Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
  }) async {
    if (BubbleWindow.isBubble) {
      await BubbleWindow.openMainApp();
      return null;
    }
    return FilePicker.platform.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      allowMultiple: allowMultiple,
      withData: withData,
    );
  }
}
