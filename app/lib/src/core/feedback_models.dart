import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';

enum FeedbackCategory {
  bug(AppStrings.feedbackBug),
  suggestion(AppStrings.feedbackSuggestion),
  other(AppStrings.feedbackOther);

  const FeedbackCategory(this.labelKey);

  /// 分类名的**唯一来源**是文案表；枚举只持键，按当前语言取词。
  final String labelKey;

  String label(BuildContext context) => context.tr(labelKey);
}

enum FeedbackStatus {
  open(AppStrings.conflictStatusPending),
  inProgress(AppStrings.feedbackStatusInProgress),
  resolved(AppStrings.feedbackStatusResolved);

  const FeedbackStatus(this.labelKey);

  final String labelKey;

  String label(BuildContext context) => context.tr(labelKey);

  static FeedbackStatus parse(String value) => switch (value) {
    'open' => open,
    'in_progress' => inProgress,
    'resolved' => resolved,
    _ => throw const FormatException(AppStrings.feedbackStatusUnknown),
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
