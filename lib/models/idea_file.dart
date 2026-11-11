import 'dart:convert';

class IdeaFile {
  final int? id;
  final int ideaId;
  final int projectId;
  final String name;
  final String type; // text, image, audio, binary
  final String? content; // base64 for binary/image, plain for text
  final String? caption; // ছবির নিজের ক্যাপশন/নোট (শুধু ওই ছবির জন্য)
  final int version;
  final int createdAt;
  final int updatedAt;

  IdeaFile({
    this.id, required this.ideaId, required this.projectId,
    required this.name, required this.type, this.content, this.caption,
    this.version = 1, required this.createdAt, required this.updatedAt,
  });

  String get ext {
    final parts = name.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : '';
  }

  String get baseName {
    final parts = name.split('.');
    return parts.length > 1
        ? parts.sublist(0, parts.length - 1).join('.') : name;
  }

  static const _imageExts = ['png','jpg','jpeg','gif','webp','svg','bmp','ico'];
  static const _textExts  = ['txt','md','dart','js','jsx','ts','tsx','py','java',
    'kt','swift','c','cpp','h','cs','go','rb','php','html','css','scss','json',
    'xml','yml','yaml','sh','bat','sql','r','m','pl','rs','lua','toml','ini',
    'env','gitignore','gradle','properties','lock'];
  static const _audioExts = ['mp3','wav','m4a','aac','ogg','flac'];
  static const _videoExts = ['mp4','mov','avi','mkv','webm'];
  static const _pdfExts   = ['pdf'];

  bool get isImage  => _imageExts.contains(ext);
  bool get isText   => _textExts.contains(ext) || type == 'text';
  bool get isAudio  => _audioExts.contains(ext) || type == 'audio';
  bool get isVideo  => _videoExts.contains(ext);
  bool get isPdf    => _pdfExts.contains(ext);
  bool get isBinary => !isText;

  int get lineCount => isText ? (content?.split('\n').length ?? 0) : 0;

  int get sizeBytes {
    if (content == null) return 0;
    if (isText) return content!.length;
    try { return base64Decode(content!).length; } catch (_) { return 0; }
  }

  String get sizeLabel {
    final b = sizeBytes;
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  factory IdeaFile.fromMap(Map<String, dynamic> m) => IdeaFile(
    id: m['id'], ideaId: m['idea_id'], projectId: m['project_id'],
    name: m['name'], type: m['type'], content: m['content'],
    caption: m['caption'],
    version: m['version'] ?? 1,
    createdAt: m['created_at'], updatedAt: m['updated_at'],
  );

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'idea_id': ideaId, 'project_id': projectId,
    'name': name, 'type': type, 'content': content, 'caption': caption,
    'version': version, 'created_at': createdAt, 'updated_at': updatedAt,
  };

  IdeaFile copyWith({
    int? id, int? ideaId, int? projectId, String? name,
    String? type, String? content, String? caption, int? version,
    int? createdAt, int? updatedAt,
  }) => IdeaFile(
    id: id ?? this.id, ideaId: ideaId ?? this.ideaId,
    projectId: projectId ?? this.projectId,
    name: name ?? this.name, type: type ?? this.type,
    content: content ?? this.content, caption: caption ?? this.caption,
    version: version ?? this.version,
    createdAt: createdAt ?? this.createdAt, updatedAt: updatedAt ?? this.updatedAt,
  );
}
