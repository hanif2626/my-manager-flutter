import 'package:flutter/material.dart';
import '../../reminder/models/reminder.dart' show bn;
import '../../widgets/app_theme.dart';
import '../radar/radar_service.dart';
import 'job_tags.dart';

/// আমার জব প্রোফাইল। এখন: 🏷️ ট্যাগ (সার্কুলার ফিল্টার/অগ্রাধিকারের জন্য)।
/// আবেদন-ফর্মের মতো ব্যক্তিগত তথ্যের ঘরগুলো পরের ধাপে এই স্ক্রিনেই আলাদা অংশ হিসেবে যোগ হবে।
class JobProfileScreen extends StatefulWidget {
  const JobProfileScreen({super.key});
  @override
  State<JobProfileScreen> createState() => _JobProfileScreenState();
}

class _JobProfileScreenState extends State<JobProfileScreen> {
  List<JobTag> _tags = [];

  @override
  void initState() {
    super.initState();
    _tags = JobTags.all();
  }

  Future<void> _save() async {
    await JobTags.saveAll(_tags);
    if (mounted) setState(() {});
  }

  /// এখন ফিডে ট্যাগটা কয়টা সার্কুলারে মেলে — শব্দ ঠিক আছে কি না যাচাই করতে।
  int _matches(JobTag t) {
    final feed = RadarService.cached();
    if (feed == null) return 0;
    return feed.items.where((i) => JobTags.match(i, tags: [t]).isNotEmpty).length;
  }

  Future<void> _edit({int? index}) async {
    final cur = index == null ? null : _tags[index];
    final nameCtrl = TextEditingController(text: cur?.name ?? '');
    final wordsCtrl = TextEditingController(text: cur?.words.join(', ') ?? '');
    String? err;
    final res = await showDialog<JobTag>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: AppTheme.bg2,
          title: Text(cur == null ? 'নতুন ট্যাগ' : 'ট্যাগ বদলাও'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'ট্যাগের নাম',
                  hintText: 'যেমন: আনসার, কম্পিউটার',
                  errorText: err,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: wordsCtrl,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'আরও যেসব শব্দে মিলবে (কমা দিয়ে, না দিলেও চলে)',
                  hintText: 'যেমন: আনসার-ভিডিপি, ভিডিপি, Ansar',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'সার্কুলারের প্রতিষ্ঠান বা পদের নামে এই শব্দগুলোর যেকোনোটা থাকলে ট্যাগটা সেই সার্কুলারে বসবে। '
                'ইংরেজি-বাংলা দুভাবেই লিখে রাখলে ভালো।',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.4),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
            TextButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  setS(() => err = 'নাম লিখতে হবে');
                  return;
                }
                final dup = _tags.asMap().entries.any((e) => e.key != index && e.value.name.toLowerCase() == name.toLowerCase());
                if (dup) {
                  setS(() => err = 'এই নামে ট্যাগ আছে');
                  return;
                }
                final words = wordsCtrl.text
                    .split(RegExp(r'[,،;\n]'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                Navigator.pop(ctx, JobTag(name, words));
              },
              child: Text('সেভ', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    wordsCtrl.dispose();
    if (res == null) return;
    setState(() {
      if (index == null) {
        _tags.add(res);
      } else {
        _tags[index] = res;
      }
    });
    await _save();
  }

  Future<void> _delete(int i) async {
    final t = _tags[i];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg2,
        title: Text('"${t.name}" ট্যাগ মুছবে?'),
        content: const Text('সার্কুলারের তালিকা আর বদলাবে না, শুধু এই ট্যাগের চিহ্ন ও ফিল্টার চলে যাবে।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('না')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('মুছো', style: TextStyle(color: AppTheme.red))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _tags.removeAt(i));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: const Text('আমার জব প্রোফাইল')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.accent,
        foregroundColor: Colors.white,
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('নতুন ট্যাগ'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.accent.withOpacity(0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('🏷️ ট্যাগ', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'নিজের পরিচয়/যোগ্যতার ট্যাগ এখানে যোগ করো — যে বিষয়ে সার্কুলারে অগ্রাধিকার বা সুবিধা মেলে। '
              'যে সার্কুলারে ট্যাগ মিলবে সেখানে ট্যাগের চিহ্ন বসবে, আর রাডারে ট্যাগ ধরে ফিল্টার ও "ট্যাগ-মিল আগে" সাজানো যাবে।',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, height: 1.45),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        if (_tags.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(children: [
              Icon(Icons.sell_outlined, size: 44, color: AppTheme.textMuted),
              const SizedBox(height: 10),
              Text('এখনো কোনো ট্যাগ নেই', style: TextStyle(color: AppTheme.textSecondary, fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('নিচের "নতুন ট্যাগ" চেপে নিজের ট্যাগ যোগ করো।', style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5)),
            ]),
          ),
        for (var i = 0; i < _tags.length; i++) _tagCard(i),
      ]),
    );
  }

  Widget _tagCard(int i) {
    final t = _tags[i];
    final n = _matches(t);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('🏷️ ${t.name}', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15.5, fontWeight: FontWeight.w800)),
            if (t.words.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final w in t.words)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppTheme.bg, borderRadius: BorderRadius.circular(10)),
                    child: Text(w, style: TextStyle(color: AppTheme.textSecondary, fontSize: 11.5)),
                  ),
              ]),
            ],
            const SizedBox(height: 6),
            Text(
              n > 0 ? 'এখন ${bn(n)}টি সার্কুলারে মিলেছে' : 'এখনকার সার্কুলারে মেলেনি',
              style: TextStyle(color: n > 0 ? AppTheme.green : AppTheme.textMuted, fontSize: 12),
            ),
          ]),
        ),
        IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _edit(index: i)),
        IconButton(icon: Icon(Icons.delete_outline_rounded, size: 20, color: AppTheme.red), onPressed: () => _delete(i)),
      ]),
    );
  }
}
