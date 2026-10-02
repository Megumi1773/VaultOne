/// 动态字段类型的展示辅助（计划书 §3.1）。
///
/// **有效性的权威在内核**（`crates/vault-core/src/item.rs` 的 `normalize_date` /
/// `ItemData::check_field`）：这里只做「把日期格式化进输入框」和「把输入框里的日期解析成
/// 选择器初值」这两件展示上的事。所以这里不实现闰年、不实现月份天数——那种规则一旦有两份，
/// 迟早会出现「界面说可以、内核说不行」。
library;

import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
import 'models.dart';

/// 把日期写成内核规范化的格式 `YYYY-MM-DD`。
String formatDateValue(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 宽松解析用户手打的日期，接受 `-` / `/` / `.` 三种分隔符；解析不了返回 null。
///
/// 只用于给日期选择器一个初值，**不用于判断能不能保存**。因此这里不校验月份天数，
/// 反正 `DateTime` 会把越界的日期滚动到下一个月，而真正的合法性判断在内核。
DateTime? parseDateValue(String raw) {
  final s = raw.trim();
  final sep = RegExp(r'[-/.]').firstMatch(s)?.group(0);
  if (sep == null) return null;
  final parts = s.split(sep);
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// 图片字段的值是不是远程地址（否则按本地路径处理）。
bool isRemoteImage(String value) {
  final v = value.trim().toLowerCase();
  return v.startsWith('http://') || v.startsWith('https://');
}

/// 字段类型的显示名。编辑器与详情页共用，避免两处各写一份 switch。
String fieldKindLabel(BuildContext context, FieldKind kind) => context.tr(switch (kind) {
      FieldKind.text => AppStrings.fieldKindText,
      FieldKind.date => AppStrings.fieldKindDate,
      FieldKind.image => AppStrings.fieldKindImage,
    });
