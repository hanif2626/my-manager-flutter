class Idea {
  final int? id;
  final int projectId;
  final String title;
  final String? description;
  final String status; // todo, doing, done
  final String priority; // low, medium, high
  final int isArchived; // 0 = visible, 1 = archived (done ideas)
  final int? deadline; // epoch ms, nullable
  final int createdAt;
  final int updatedAt;

  Idea({
    this.id,
    required this.projectId,
    required this.title,
    this.description,
    this.status = 'todo',
    this.priority = 'medium',
    this.isArchived = 0,
    this.deadline,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isOverdue {
    if (deadline == null) return false;
    if (status == 'done') return false;
    return DateTime.now().millisecondsSinceEpoch > deadline!;
  }

  bool get isDueToday {
    if (deadline == null) return false;
    final d = DateTime.fromMillisecondsSinceEpoch(deadline!);
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  factory Idea.fromMap(Map<String, dynamic> m) => Idea(
        id: m['id'],
        projectId: m['project_id'],
        title: m['title'],
        description: m['description'],
        status: const {'todo', 'doing', 'done'}.contains(m['status'])
            ? m['status'] as String
            : 'todo',
        priority: const {'low', 'medium', 'high'}.contains(m['priority'])
            ? m['priority'] as String
            : 'medium',
        isArchived: m['is_archived'] ?? 0,
        deadline: m['deadline'],
        createdAt: m['created_at'],
        updatedAt: m['updated_at'],
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'project_id': projectId,
        'title': title,
        'description': description,
        'status': status,
        'priority': priority,
        'is_archived': isArchived,
        'deadline': deadline,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Idea copyWith({
    int? id, int? projectId, String? title, String? description,
    String? status, String? priority, int? isArchived,
    Object? deadline = _sentinel,
    int? createdAt, int? updatedAt,
  }) => Idea(
        id: id ?? this.id,
        projectId: projectId ?? this.projectId,
        title: title ?? this.title,
        description: description ?? this.description,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        isArchived: isArchived ?? this.isArchived,
        deadline: deadline == _sentinel ? this.deadline : deadline as int?,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

const _sentinel = Object();
