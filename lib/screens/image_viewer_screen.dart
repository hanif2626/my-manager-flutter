import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import '../models/idea_file.dart';
import '../widgets/app_theme.dart';
import '../widgets/safe_base64_image.dart';

class ImageViewerScreen extends StatelessWidget {
  final IdeaFile file;
  const ImageViewerScreen({super.key, required this.file});

  Future<void> _share(BuildContext context) async {
    if (file.content == null) return;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${file.name}');
    await f.writeAsBytes(base64Decode(file.content!));
    await Share.shareXFiles([XFile(f.path)], text: file.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(file.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace')),
          Text('v${file.version}', style: const TextStyle(color: AppTheme.accent, fontSize: 11)),
        ]),
        actions: [
          IconButton(
            onPressed: () => _share(context),
            icon: const Icon(Icons.share_outlined, color: Colors.white),
          ),
        ],
      ),
      body: file.content != null
          ? InteractiveViewer(
              minScale: 0.5, maxScale: 5.0,
              child: Center(
                child: SafeBase64Image(data: file.content!, fit: BoxFit.contain,
                    fallback: const Center(
                        child: Text('ছবি লোড হয়নি', style: TextStyle(color: Colors.white)))),
              ),
            )
          : const Center(child: Text('No image', style: TextStyle(color: Colors.white))),
    );
  }
}
