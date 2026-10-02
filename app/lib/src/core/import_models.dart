/// 导入预览与字段映射（计划书 §3.7）的模型。
///
/// 解析与列映射的规则**只在内核实现一处**（`crates/vault-core/src/import.rs`），
/// 这里只做反序列化与展示辅助，不重复任何别名表或识别逻辑。
library;

/// 可以映射的目标字段。顺序即界面里下拉框的顺序（常用字段在前）。
enum ImportField {
  title('title'),
  url('url'),
  username('username'),
  password('password'),
  totp('totp'),
  notes('notes'),
  favorite('favorite'),
  category('category'),
  tags('tags'),
  kind('kind'),
  fields('fields');

  const ImportField(this.wire);

  /// 与内核 `ColumnMapping` 的 serde 字段名一致。
  final String wire;
}

/// 遇到同名条目时的处理策略。
enum ImportStrategy {
  skip('skip'),
  overwrite('overwrite'),
  keepBoth('keepBoth');

  const ImportStrategy(this.wire);

  final String wire;
}

/// 源列 → 目标字段的映射。值是该字段对应的列下标，null 表示不映射。
class ColumnMapping {
  const ColumnMapping(this.columns);

  factory ColumnMapping.fromJson(Map<String, dynamic> j) => ColumnMapping({
        for (final f in ImportField.values)
          if (j[f.wire] is num) f: (j[f.wire] as num).toInt(),
      });

  factory ColumnMapping.fromPreviewJson(Map<String, dynamic> j) =>
      ColumnMapping.fromJson(((j['mapping'] as Map?) ?? const {}).cast());

  final Map<ImportField, int> columns;

  int? operator [](ImportField field) => columns[field];

  /// 改一个字段的映射，返回新映射（不改原对象）。
  ColumnMapping withField(ImportField field, int? column) {
    final next = Map<ImportField, int>.from(columns);
    if (column == null) {
      next.remove(field);
    } else {
      next[field] = column;
    }
    return ColumnMapping(next);
  }

  Map<String, Object?> toJson() => {
        for (final e in columns.entries) e.key.wire: e.value,
      };

  bool get isEmpty => columns.isEmpty;
}

/// 一次导入预览。
class ImportPreview {
  const ImportPreview({
    required this.format,
    required this.headers,
    required this.sampleRows,
    required this.totalRows,
    required this.items,
    required this.skipped,
    required this.warnings,
    required this.mapping,
    required this.unusedColumns,
  });

  factory ImportPreview.fromJson(Map<String, dynamic> j) => ImportPreview(
        format: j['format'] as String? ?? '',
        headers: [for (final h in (j['headers'] as List? ?? const [])) h as String],
        sampleRows: [
          for (final r in (j['sampleRows'] as List? ?? const []))
            [for (final c in (r as List)) c as String],
        ],
        totalRows: (j['totalRows'] as num?)?.toInt() ?? 0,
        items: [for (final i in (j['items'] as List? ?? const [])) i as Map],
        skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        warnings: [for (final w in (j['warnings'] as List? ?? const [])) w as String],
        mapping: ColumnMapping.fromJson(((j['mapping'] as Map?) ?? const {}).cast()),
        unusedColumns: [for (final c in (j['unusedColumns'] as List? ?? const [])) c as String],
      );

  /// 识别出的来源：chrome / firefox / bitwarden / lastpass / 1password / 1pif / csv
  final String format;

  /// CSV 表头；1PIF 为空（没有列可映射）。
  final List<String> headers;

  /// 原始数据的前若干行，与 [headers] 一一对应。
  final List<List<String>> sampleRows;

  /// 数据行总数（不含表头）。
  final int totalRows;

  /// 解析出的条目（尚未入库）。界面只用来计数，不直接展示明文。
  final List<Map<dynamic, dynamic>> items;

  final int skipped;
  final List<String> warnings;
  final ColumnMapping mapping;
  final List<String> unusedColumns;

  /// 可导入的条目数。
  int get importable => items.length;

  /// 是否有列可映射（1PIF 没有）。
  bool get canMapColumns => headers.isNotEmpty;

  /// 预览是否被截断（实际行数多于展示行数）。没有样例表（如 1PIF）时谈不上截断。
  bool get truncated => sampleRows.isNotEmpty && totalRows > sampleRows.length;
}
