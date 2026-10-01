enum FeedbackCategory {
  bug('问题反馈'),
  suggestion('功能建议'),
  other('其他');

  const FeedbackCategory(this.label);
  final String label;
}

enum FeedbackStatus {
  open('待处理'),
  inProgress('处理中'),
  resolved('已处理');

  const FeedbackStatus(this.label);
  final String label;

  static FeedbackStatus parse(String value) => switch (value) {
    'open' => open,
    'in_progress' => inProgress,
    'resolved' => resolved,
    _ => throw const FormatException('无法识别反馈状态'),
  };
}

class FeedbackSubmission {
  const FeedbackSubmission({
    required this.id,
    required this.category,
    required this.content,
    this.contact,
  });

  final String id;
  final FeedbackCategory category;
  final String content;
  final String? contact;

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.name,
    'content': content,
    'contact': contact,
    'consent': true,
  };
}

class FeedbackSummary {
  const FeedbackSummary({
    required this.id,
    required this.category,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
  });

  factory FeedbackSummary.fromJson(Map<String, dynamic> json) =>
      FeedbackSummary(
        id: json['id'] as String,
        category: FeedbackCategory.values.byName(json['category'] as String),
        status: FeedbackStatus.parse(json['status'] as String),
        createdAt: json['created_at'] as int,
        updatedAt: json['updated_at'] as int,
        version: json['version'] as int,
      );

  final String id;
  final FeedbackCategory category;
  final FeedbackStatus status;
  final int createdAt;
  final int updatedAt;
  final int version;
}

class FeedbackDetail {
  const FeedbackDetail({
    required this.summary,
    required this.content,
    this.contact,
    this.reply,
  });

  factory FeedbackDetail.fromJson(Map<String, dynamic> json) => FeedbackDetail(
    summary: FeedbackSummary.fromJson(json),
    content: json['content'] as String,
    contact: json['contact'] as String?,
    reply: json['reply'] as String?,
  );

  final FeedbackSummary summary;
  final String content;
  final String? contact;
  final String? reply;
}

class FeedbackPageResult {
  FeedbackPageResult({required List<FeedbackSummary> items, this.nextBefore})
    : items = List.unmodifiable(items);

  factory FeedbackPageResult.fromJson(Map<String, dynamic> json) =>
      FeedbackPageResult(
        items: (json['items'] as List)
            .map(
              (item) => FeedbackSummary.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        nextBefore: json['next_before'] as int?,
      );

  final List<FeedbackSummary> items;
  final int? nextBefore;
}
