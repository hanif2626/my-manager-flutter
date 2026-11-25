/// Additive ব্যাকআপ-মার্জ — শুধু বিশুদ্ধ ফাংশন (কোনো I/O নেই), তাই
/// ইউনিট-টেস্টে সরাসরি যাচাই করা যায়।
///
/// ব্যবহারকারীর নির্দেশ (২০২৬-১১-২৫): ব্যাকআপ কখনো ওভাররাইট নয়।
/// Drive-এ যা আছে তা থাকবে; ফোনের নতুনটা শুধু যোগ হবে — শতভাগ নিশ্চিত।
///
/// নিয়ম:
///  ১. Drive-এ আছে, ফোনে নেই → অক্ষত থাকে (kept)। এটাই মূল সুরক্ষা:
///     ফোনে কিছু মুছে গেলেও (ভুলে ডিলিট, ডাটা নষ্ট) Drive-এর কপি বাঁচে।
///  ২. ফোনে আছে, Drive-এ নেই → যোগ হয় (added)।
///  ৩. দুই জায়গায় একই চাবি:
///     • updated_at/updatedAt থাকলে যার নতুন সে জেতে (updated);
///     • না থাকলে ফোনের (লোকাল) সংস্করণ থাকে — ফোনই চলমান উৎস;
///       তবে বিষয়বস্তু হুবহু এক হলে সেটা kept (বদল হয়নি)।
///  ৪. Drive-এর ফাইল নামানো/পড়া না গেলে মার্জ হয় না — কলার তখন
///     আপলোডও করে না (fail-safe)। এই ফাইলে সেই সিদ্ধান্ত নেই;
///     এখানে শুধু দুটো সুস্থ ম্যাপের মার্জ।
///
/// চাবিগুলো রিস্টোর-মার্জের সাথে হুবহু মিলিয়ে নেওয়া (যাতে ব্যাকআপে
/// যা জোড়া লাগে, রিস্টোরেও ঠিক সেটাই জোড়া লাগে)।
class AdditiveCounts {
  final int kept;
  final int added;
  final int updated;
  const AdditiveCounts({this.kept = 0, this.added = 0, this.updated = 0});
  int get total => kept + added + updated;
  Map<String, dynamic> toJson() =>
      {'kept': kept, 'added': added, 'updated': updated};
  static AdditiveCounts fromJson(Map<String, dynamic> m) => AdditiveCounts(
        kept: m['kept'] as int? ?? 0,
        added: m['added'] as int? ?? 0,
        updated: m['updated'] as int? ?? 0,
      );
  AdditiveCounts operator +(AdditiveCounts o) => AdditiveCounts(
        kept: kept + o.kept,
        added: added + o.added,
        updated: updated + o.updated,
      );
}

class AdditiveMergeResult {
  final Map<String, dynamic> json;
  final AdditiveCounts counts;
  const AdditiveMergeResult(this.json, this.counts);
}

class AdditiveMerge {
  static List<Map<String, dynamic>> _rows(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static bool _deepEq(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// দুই তালিকার মার্জ। ফেরত: মার্জ করা তালিকা + হিসাব।
  /// [keyOf] চাবি বানায়; [timeKey] থাকলে নতুন সময় জেতে; না থাকলে
  /// [localWins] true হলে ফোনেরটা বসে, false/null হলে Drive-এরটা থাকে।
  static ({List<Map<String, dynamic>> rows, AdditiveCounts counts})
      _mergeLists(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote, {
    required String Function(Map<String, dynamic> row) keyOf,
    String? timeKey,
    bool Function(Map<String, dynamic> local, Map<String, dynamic> remote)?
        localWins,
  }) {
    final out = <String, Map<String, dynamic>>{};
    final order = <String>[];
    var added = 0, updated = 0;
    // প্রথমে Drive-এরটা — এগুলোই "আগের যা আছে"।
    for (final r in remote) {
      final k = keyOf(r);
      if (k.isEmpty || out.containsKey(k)) continue;
      out[k] = r;
      order.add(k);
    }
    final remoteUnique = order.length;
    for (final l in local) {
      final k = keyOf(l);
      if (k.isEmpty) continue;
      final r = out[k];
      if (r == null) {
        out[k] = l;
        order.add(k);
        added++;
      } else if (_deepEq(l, r)) {
        // একই জিনিস — কিছু বদলায়নি।
      } else if (timeKey != null) {
        final lt = l[timeKey] as int? ?? 0;
        final rt = r[timeKey] as int? ?? 0;
        if (lt > rt) {
          out[k] = l;
          updated++;
        }
        // লোকাল পুরনো হলে Drive-এরটাই থাকে।
      } else if (localWins != null && localWins(l, r)) {
        out[k] = l;
        updated++;
      }
      // localWins false/null আর সময়ও নেই → Drive-এরটা থাকে।
    }
    final kept = remoteUnique - updated;
    return (
      rows: [for (final k in order) out[k]!],
      counts: AdditiveCounts(kept: kept, added: added, updated: updated),
    );
  }

  static Map<String, dynamic> _finish(
      Map<String, dynamic> local, Map<String, dynamic> merged) {
    final out = Map<String, dynamic>.from(merged);
    out['version'] = local['version'];
    out['exported_at'] = DateTime.now().toIso8601String();
    return out;
  }

  static String _idKey(Map<String, dynamic> r) =>
      (r['id'] == null) ? '' : '${r['id']}';

  /// প্রজেক্ট/আইডিয়া (mymanager_backup.json)। রিস্টোরের _importFromJson-এর
  /// সাথে হুবহু এক নিয়ম: id + updated_at; project_versions শুধু id।
  static AdditiveMergeResult mergeMain(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final merged = <String, dynamic>{};
    var counts = const AdditiveCounts();
    for (final t in ['projects', 'ideas', 'idea_files', 'checklist_items']) {
      final m = _mergeLists(_rows(local[t]), _rows(remote[t]),
          keyOf: _idKey, timeKey: 'updated_at');
      merged[t] = m.rows;
      counts += m.counts;
    }
    final pv = _mergeLists(_rows(local['project_versions']),
        _rows(remote['project_versions']),
        keyOf: _idKey, localWins: (_, __) => true);
    merged['project_versions'] = pv.rows;
    counts += pv.counts;
    return AdditiveMergeResult(_finish(local, merged), counts);
  }

  /// ক্যাশবুক (cashbook_backup.json)। importAll-এর সাথে এক নিয়ম:
  /// entries-এ updated_at; বাকি টেবিলে id; budgets-এ category।
  static AdditiveMergeResult mergeCashbook(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final merged = <String, dynamic>{};
    var counts = const AdditiveCounts();
    for (final t in ['accounts', 'debts', 'essentials']) {
      final m = _mergeLists(_rows(local[t]), _rows(remote[t]),
          keyOf: _idKey, localWins: (_, __) => true);
      merged[t] = m.rows;
      counts += m.counts;
    }
    final en = _mergeLists(_rows(local['entries']), _rows(remote['entries']),
        keyOf: _idKey, timeKey: 'updated_at');
    merged['entries'] = en.rows;
    counts += en.counts;
    final bu = _mergeLists(_rows(local['budgets']), _rows(remote['budgets']),
        keyOf: (r) => (r['category'] as String?) ?? '',
        localWins: (_, __) => true);
    merged['budgets'] = bu.rows;
    counts += bu.counts;
    return AdditiveMergeResult(_finish(local, merged), counts);
  }

  /// পরিবার (family_backup.json)। export-এ id থাকে না — রিস্টোরের
  /// মতোই প্রাকৃতিক চাবি: নাম+জন্মতারিখ / শিরোনাম+তারিখ /
  /// শিরোনাম+ডিউ ডে / নাম+ফোন।
  static AdditiveMergeResult mergeFamily(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    String sig(List<String> parts) => parts.join('\u0001');
    final merged = <String, dynamic>{};
    var counts = const AdditiveCounts();
    final specs = <String, String Function(Map<String, dynamic>)>{
      'members': (r) => sig(
          ['${r['name'] ?? ''}', '${r['birth_date'] ?? ''}']),
      'dates': (r) =>
          sig(['${r['title'] ?? ''}', '${r['date'] ?? ''}']),
      'bills': (r) => sig(
          ['${r['title'] ?? ''}', '${r['dueDay'] ?? ''}']),
      'contacts': (r) =>
          sig(['${r['name'] ?? ''}', '${r['phone'] ?? ''}']),
    };
    for (final e in specs.entries) {
      final m = _mergeLists(_rows(local[e.key]), _rows(remote[e.key]),
          keyOf: e.value, localWins: (_, __) => true);
      merged[e.key] = m.rows;
      counts += m.counts;
    }
    return AdditiveMergeResult(_finish(local, merged), counts);
  }

  /// চাকরি (jobs_backup.json)। সার্কুলার: শিরোনাম+পদ+শেষ তারিখ;
  /// ডকুমেন্ট: শিরোনাম — টিক (done) যেদিকে true সেদিক জেতে;
  /// প্রোফাইল: লোকালে ফাঁকা ঘর থাকলে Drive-এর মান বসে।
  static AdditiveMergeResult mergeJobs(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    final merged = <String, dynamic>{};
    var counts = const AdditiveCounts();
    final ci = _mergeLists(
        _rows(local['circulars']), _rows(remote['circulars']),
        keyOf: (r) => [
              '${r['title'] ?? ''}',
              '${r['post'] ?? ''}',
              '${r['deadline'] ?? ''}'
            ].join('\u0001'),
        localWins: (_, __) => true);
    merged['circulars'] = ci.rows;
    counts += ci.counts;
    final docs = _mergeLists(_rows(local['docs']), _rows(remote['docs']),
        keyOf: (r) => (r['title'] as String?) ?? '',
        localWins: (l, r) => l['done'] == true && r['done'] != true);
    merged['docs'] = docs.rows;
    counts += docs.counts;
    final lp = local['profile'];
    final rp = remote['profile'];
    if (lp is Map && rp is Map) {
      final p = Map<String, dynamic>.from(lp);
      var filled = 0;
      for (final k in rp.keys) {
        final lv = p[k];
        if ((lv == null || (lv is String && lv.isEmpty)) && rp[k] != null) {
          p[k] = rp[k];
          filled++;
        }
      }
      merged['profile'] = p;
      if (filled > 0) counts += const AdditiveCounts(updated: 1);
    } else if (lp is Map) {
      merged['profile'] = Map<String, dynamic>.from(lp);
    } else if (rp is Map) {
      merged['profile'] = Map<String, dynamic>.from(rp);
      counts += const AdditiveCounts(added: 1);
    }
    return AdditiveMergeResult(_finish(local, merged), counts);
  }

  /// রিমাইন্ডার (reminders_backup.json)। চাবি রিস্টোরের _sig-এর মতো:
  /// শিরোনাম+তারিখ+সময়+রিপিট (export-এ times আগেই সাজানো স্ট্রিং)।
  static AdditiveMergeResult mergeReminders(
      Map<String, dynamic> local, Map<String, dynamic> remote) {
    String sig(Map<String, dynamic> r) => [
          '${r['title'] ?? ''}',
          '${r['date'] ?? ''}',
          '${r['times'] ?? ''}',
          '${r['repeat'] ?? ''}',
        ].join('\u0001');
    final m = _mergeLists(_rows(local['reminders']),
        _rows(remote['reminders']),
        keyOf: sig, localWins: (_, __) => true);
    return AdditiveMergeResult(
        _finish(local, {'reminders': m.rows}), m.counts);
  }

  /// ভল্ট এন্ট্রির তালিকার মার্জ (id String + updatedAt int)।
  /// VaultService.mergeMany-এর সাথে এক নিয়ম: নতুন updatedAt জেতে।
  static ({List<Map<String, dynamic>> entries, AdditiveCounts counts})
      mergeVaultEntries(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) {
    final m = _mergeLists(local, remote,
        keyOf: (r) => (r['id'] as String?) ?? '', timeKey: 'updatedAt');
    return (entries: m.rows, counts: m.counts);
  }
}
