import 'package:flutter_test/flutter_test.dart';
import 'package:my_manager/services/additive_merge.dart';

// Additive ব্যাকআপ-মার্জের নিয়ম-যাচাই (২০২৬-১১-২৫)।
// মূল দাবি: Drive-এ যা আছে তা থাকবে; ফোনের নতুনটা শুধু যোগ হবে।
// ফোনে কিছু মুছে গেলেও Drive-এর কপি থেকে সেটা হারাবে না।

void main() {
  group('mergeMain', () {
    test('Drive-এ আছে, ফোনে নেই → অক্ষত থাকে', () {
      final local = {
        'version': 3,
        'projects': [
          {'id': 1, 'title': 'ফোনের প্রজেক্ট', 'updated_at': 100},
        ],
        'ideas': [],
        'idea_files': [],
        'project_versions': [],
        'checklist_items': [],
      };
      final remote = {
        'version': 3,
        'projects': [
          {'id': 1, 'title': 'ফোনের প্রজেক্ট', 'updated_at': 100},
          {'id': 2, 'title': 'আগের প্রজেক্ট', 'updated_at': 90},
        ],
        'ideas': [],
        'idea_files': [],
        'project_versions': [],
        'checklist_items': [],
      };
      final r = AdditiveMerge.mergeMain(local, remote);
      final projects = r.json['projects'] as List;
      expect(projects.length, 2);
      expect(projects.any((p) => p['id'] == 2), true);
      // kept = Drive-এর যে ২টি সারি অপরিবর্তিত থাকল (id ১ হুবহু এক + id ২ শুধু Drive-এ)।
      expect(r.counts.kept, 2);
      expect(r.counts.added, 0);
    });

    test('নতুন updated_at জেতে — দুই দিকেই', () {
      final local = {
        'version': 3,
        'projects': [
          {'id': 1, 'title': 'নতুন নাম', 'updated_at': 200},
        ],
        'ideas': [],
        'idea_files': [],
        'project_versions': [],
        'checklist_items': [],
      };
      final remote = {
        'version': 3,
        'projects': [
          {'id': 1, 'title': 'পুরনো নাম', 'updated_at': 100},
        ],
        'ideas': [],
        'idea_files': [],
        'project_versions': [],
        'checklist_items': [],
      };
      var r = AdditiveMerge.mergeMain(local, remote);
      expect((r.json['projects'] as List).first['title'], 'নতুন নাম');
      expect(r.counts.updated, 1);
      // উল্টো: ফোনেরটা পুরনো হলে Drive-এরটাই থাকে।
      r = AdditiveMerge.mergeMain(remote, local);
      expect((r.json['projects'] as List).first['title'], 'নতুন নাম');
      expect(r.counts.kept, 1);
      expect(r.counts.updated, 0);
    });
  });

  group('mergeCashbook', () {
    test('ফোনে মুছে যাওয়া এন্ট্রি Drive-এর কপিতে বাঁচে', () {
      final local = {
        'version': 1,
        'accounts': [],
        'entries': [
          {'id': 1, 'amount': 500, 'updated_at': 100},
        ],
        'budgets': [],
        'debts': [],
        'essentials': [],
      };
      final remote = {
        'version': 1,
        'accounts': [],
        'entries': [
          {'id': 1, 'amount': 500, 'updated_at': 100},
          {'id': 2, 'amount': 700, 'updated_at': 90},
        ],
        'budgets': [],
        'debts': [],
        'essentials': [],
      };
      final r = AdditiveMerge.mergeCashbook(local, remote);
      expect((r.json['entries'] as List).length, 2);
      expect(r.counts.kept, 2);
    });
  });

  group('mergeFamily', () {
    test('একই সদস্য দুবার যোগ হয় না; আগের সদস্য থাকে', () {
      final local = {
        'version': 1,
        'members': [
          {'name': 'হানিফ', 'birth_date': '1990-01-01'},
        ],
        'dates': [],
        'bills': [],
        'contacts': [],
      };
      final remote = {
        'version': 1,
        'members': [
          {'name': 'হানিফ', 'birth_date': '1990-01-01'},
          {'name': 'শিরিন', 'birth_date': '1992-05-05'},
        ],
        'dates': [],
        'bills': [],
        'contacts': [],
      };
      final r = AdditiveMerge.mergeFamily(local, remote);
      expect((r.json['members'] as List).length, 2);
      expect(r.counts.kept, 2);
      expect(r.counts.added, 0);
    });
  });

  group('mergeJobs', () {
    test('ডকুমেন্টে টিক যেদিকে true সেদিক জেতে', () {
      final local = {
        'version': 1,
        'circulars': [],
        'docs': [
          {'title': 'NID', 'done': true, 'sort': 0},
        ],
        'profile': {},
      };
      final remote = {
        'version': 1,
        'circulars': [],
        'docs': [
          {'title': 'NID', 'done': false, 'sort': 0},
        ],
        'profile': {},
      };
      final r = AdditiveMerge.mergeJobs(local, remote);
      final docs = r.json['docs'] as List;
      expect(docs.length, 1);
      expect(docs.first['done'], true);
      expect(r.counts.updated, 1);
    });
  });

  group('mergeReminders', () {
    test('একই রিমাইন্ডার দুবার হয় না', () {
      final local = {
        'version': 1,
        'reminders': [
          {
            'title': 'বিল',
            'date': '2026-11-25',
            'times': '20:00',
            'repeat': 'none'
          },
        ],
      };
      final remote = {
        'version': 1,
        'reminders': [
          {
            'title': 'বিল',
            'date': '2026-11-25',
            'times': '20:00',
            'repeat': 'none'
          },
          {
            'title': 'ওষুধ',
            'date': '2026-11-25',
            'times': '09:00',
            'repeat': 'daily'
          },
        ],
      };
      final r = AdditiveMerge.mergeReminders(local, remote);
      expect((r.json['reminders'] as List).length, 2);
      expect(r.counts.kept, 2);
    });
  });

  group('mergeVaultEntries', () {
    test('পুরনো লোকাল নতুন রিমোটকে ঢাকে না', () {
      final local = [
        {'id': 'a', 'title': 'Gmail', 'updatedAt': 100},
      ];
      final remote = [
        {'id': 'a', 'title': 'Gmail নতুন', 'updatedAt': 200},
        {'id': 'b', 'title': 'ব্যাংক', 'updatedAt': 150},
      ];
      final r = AdditiveMerge.mergeVaultEntries(local, remote);
      expect(r.entries.length, 2);
      expect(r.entries.firstWhere((e) => e['id'] == 'a')['title'], 'Gmail নতুন');
      expect(r.entries.any((e) => e['id'] == 'b'), true);
      expect(r.counts.kept, 2);
      expect(r.counts.updated, 0);
    });
  });
}
