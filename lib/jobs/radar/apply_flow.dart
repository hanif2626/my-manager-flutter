import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ApplyFlow {
  /// Check if there is any pending apply flow task
  static void askIfPending(BuildContext context, VoidCallback? onSaved) {
    // Ekhane apnar proyojoniyo logic ba dialog rakhte paren
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Checking pending apply flow...')),
    );
  }

  /// Returns the best URL for the item/job
  static String bestUrl(dynamic item) {
    // Item theke valid URL return korar logic
    if (item is Map && item['url'] != null) {
      return item['url'].toString();
    }
    return '';
  }

  /// Open the application URL or flow
  static Future<void> open(BuildContext context, dynamic item) async {
    final urlString = bestUrl(item);
    if (urlString.isNotEmpty) {
      final uri = Uri.parse(urlString);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not launch $urlString')),
          );
        }
      }
    }
  }
}
