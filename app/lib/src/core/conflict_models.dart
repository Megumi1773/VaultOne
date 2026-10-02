import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
import 'models.dart';

enum ConflictState { pending, resolutionPending, resolved, superseded }

enum ConflictSide { local, remote }

enum ConflictField {
  type,
  title,
  urls,
  username,
  password,
  totp,
  notes,
  card,
  identity,
  customFields,
  favorite,
  deleted,
  resolution;

  /// 字段名的**唯一来源**是文案表；枚举只持引用，避免同一文案在两处定义而分叉。
  String labelOf(BuildContext context) => context.tr(_labelKeys[this]!);

  static const _labelKeys = <ConflictField, String>{
    ConflictField.type: AppStrings.conflictFieldKind,
    ConflictField.title: AppStrings.titleLabel,
    ConflictField.urls: AppStrings.fieldWebsite,
    ConflictField.username: AppStrings.fieldUsername,
    ConflictField.password: AppStrings.fieldPassword,
    ConflictField.totp: AppStrings.twoFactorCoverage,
    ConflictField.notes: AppStrings.fieldNotes,
    ConflictField.card: AppStrings.sectionCard,
    ConflictField.identity: AppStrings.sectionIdentity,
    ConflictField.customFields: AppStrings.customFields,
    ConflictField.favorite: AppStrings.sectionFavorites,
    ConflictField.deleted: AppStrings.conflictFieldDeleted,
    ConflictField.resolution: AppStrings.conflictFieldResolution,
  };

  bool get sensitive => switch (this) {
    type || title || favorite || deleted || resolution => false,
    _ => true,
  };
}

/// 保留候选的版本号和删除标记，不将删除误解释为字段为空。
class ConflictVersion {
  const ConflictVersion({
    required this.revision,
    required this.data,
    this.deleted,
  });
  final int revision;

  /// null 表示旧基线未记录；与明确的“未删除”不同。
  final bool? deleted;
  final ItemData data;

  factory ConflictVersion.fromJson(Map<String, dynamic> json) =>
      ConflictVersion(
        revision: (json['revision'] as num).toInt(),
        deleted: json['deleted'] as bool?,
        data: ItemData.fromJson((json['data'] as Map).cast()),
      );

  Map<String, Object?> toJson() => {
    'revision': revision,
    'deleted': deleted,
    'data': data.toJson(),
  };

  Object? value(ConflictField field) =>
      field == ConflictField.deleted ? deleted : data.toJson()[field.name];
}

class ConflictDetail {
  const ConflictDetail({
    required this.id,
    required this.itemId,
    required this.state,
    required this.stale,
    required this.fields,
    this.base,
    required this.local,
    required this.remote,
    required this.suggested,
  });

  final String id;
  final String itemId;
  final ConflictState state;
  final bool stale;
  final List<ConflictField> fields;
  final ConflictVersion? base;
  final ConflictVersion local;
  final ConflictVersion remote;
  final ItemData suggested;

  bool get canResolve => state == ConflictState.pending && !stale;
  bool get wholeOnly =>
      fields.contains(ConflictField.type) ||
      fields.contains(ConflictField.resolution);

  /// 状态名同样只来自文案表。
  String statusLabel(BuildContext context) => switch (state) {
    ConflictState.pending => context.tr(stale ? AppStrings.conflictCandidateStale : AppStrings.conflictStatusPending),
    ConflictState.resolutionPending => context.tr(AppStrings.conflictStatusAwaitingSync),
    ConflictState.resolved => context.tr(AppStrings.conflictStatusResolved),
    ConflictState.superseded => context.tr(AppStrings.conflictStatusSuperseded),
  };

  factory ConflictDetail.fromJson(Map<String, dynamic> json) => ConflictDetail(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    state: ConflictState.values.byName(json['state'] as String),
    stale: json['stale'] == true,
    fields: List.unmodifiable(
      (json['fields'] as List).map(
        (f) => ConflictField.values.byName(f as String),
      ),
    ),
    base: json['base'] == null
        ? null
        : ConflictVersion.fromJson((json['base'] as Map).cast()),
    local: ConflictVersion.fromJson((json['local'] as Map).cast()),
    remote: ConflictVersion.fromJson((json['remote'] as Map).cast()),
    suggested: ItemData.fromJson((json['suggested'] as Map).cast()),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'itemId': itemId,
    'state': state.name,
    'stale': stale,
    'fields': fields.map((f) => f.name).toList(),
    if (base != null) 'base': base!.toJson(),
    'local': local.toJson(),
    'remote': remote.toJson(),
    'suggested': suggested.toJson(),
  };

  ConflictDetail awaitingSync() => ConflictDetail(
    id: id,
    itemId: itemId,
    state: ConflictState.resolutionPending,
    stale: false,
    fields: fields,
    base: base,
    local: local,
    remote: remote,
    suggested: suggested,
  );
}

/// wire 契约：整条二选一，或每个冲突字段恰好选择一方。
class ConflictResolution {
  const ConflictResolution.whole(ConflictSide this.side) : choices = const {};
  ConflictResolution.fields(Map<ConflictField, ConflictSide> choices)
    : side = null,
      choices = Map.unmodifiable(choices);

  final ConflictSide? side;
  final Map<ConflictField, ConflictSide> choices;

  bool isValidFor(ConflictDetail detail) =>
      detail.canResolve &&
      (side != null ||
          (!detail.wholeOnly &&
              detail.fields.isNotEmpty &&
              choices.length == detail.fields.toSet().length &&
              detail.fields.every(choices.containsKey)));

  Map<String, Object?> toJson() => side != null
      ? {'mode': 'whole', 'side': side!.name}
      : {
          'mode': 'fields',
          'choices': [
            for (final entry in choices.entries)
              {'field': entry.key.name, 'side': entry.value.name},
          ],
        };
}
