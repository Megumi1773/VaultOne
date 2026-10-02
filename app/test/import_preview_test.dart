import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/core/import_models.dart';
import 'package:vaultone/src/ui/screens/import_dialog.dart';
import 'package:vaultone/src/ui/theme.dart';

Map<String, Object?> _previewJson({int totalRows = 3, int items = 2, int skipped = 1}) => {
      'format': 'csv',
      'headers': ['col1', 'col2', 'password'],
      'sampleRows': [
        ['MyBank', 'https://bank.example', 'pw1'],
        ['Mail', 'https://mail.example', 'pw2'],
      ],
      'totalRows': totalRows,
      'items': [for (var i = 0; i < items; i++) {'title': 'x$i'}],
      'skipped': skipped,
      'warnings': ['有 1 列没有被使用：col2'],
      'mapping': {'password': 2},
      'unusedColumns': ['col1', 'col2'],
    };

void main() {
  test('ColumnMapping 往返 JSON，缺字段视为未映射', () {
    const m = ColumnMapping({ImportField.title: 0, ImportField.password: 3});
    final back = ColumnMapping.fromJson(m.toJson());
    expect(back[ImportField.title], 0);
    expect(back[ImportField.password], 3);
    expect(back[ImportField.url], isNull);
    expect(back.isEmpty, isFalse);
    expect(const ColumnMapping({}).isEmpty, isTrue);

    final partial = ColumnMapping.fromJson(const {'title': 1});
    expect(partial[ImportField.title], 1);
    expect(partial[ImportField.password], isNull);
  });

  test('withField 返回新对象，不改原映射', () {
    const m = ColumnMapping({ImportField.title: 0});
    final added = m.withField(ImportField.url, 2);
    expect(added[ImportField.url], 2);
    expect(m[ImportField.url], isNull, reason: '原映射不该被就地修改');

    final removed = added.withField(ImportField.title, null);
    expect(removed[ImportField.title], isNull);
    expect(added[ImportField.title], 0);
  });

  test('ImportPreview 解析并给出派生信息', () {
    final p = ImportPreview.fromJson(_previewJson());
    expect(p.format, 'csv');
    expect(p.headers, ['col1', 'col2', 'password']);
    expect(p.totalRows, 3);
    expect(p.importable, 2);
    expect(p.skipped, 1);
    expect(p.warnings, hasLength(1));
    expect(p.mapping[ImportField.password], 2);
    expect(p.canMapColumns, isTrue);
    expect(p.truncated, isTrue, reason: '3 行数据只展示了 2 行');
  });

  test('1PIF 预览没有列可映射', () {
    final p = ImportPreview.fromJson(const {
      'format': '1pif',
      'headers': <String>[],
      'sampleRows': <List<String>>[],
      'totalRows': 1,
      'items': [
        {'title': 'x'},
      ],
      'skipped': 0,
      'warnings': <String>[],
      'mapping': <String, Object?>{},
      'unusedColumns': <String>[],
    });
    expect(p.canMapColumns, isFalse);
    expect(p.truncated, isFalse);
    expect(p.importable, 1);
  });

  group('导入预览对话框', () {
    Future<({List<ImportDecision> results, List<ColumnMapping?> parses})> mount(
      WidgetTester tester, {
      Map<String, Object?>? json,
    }) async {
      final parses = <ColumnMapping?>[];
      final results = <ImportDecision>[];
      // 对话框内容较高，默认 800×600 视口下策略选项会落在屏幕外，点击点不中。
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final decision = await showImportPreview(
                    context,
                    content: 'raw',
                    sourceName: 'export.csv',
                    parse: (c, {mapping}) async {
                      parses.add(mapping);
                      return ImportPreview.fromJson(json ?? _previewJson());
                    },
                  );
                  if (decision != null) results.add(decision);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (results: results, parses: parses);
    }

    testWidgets('展示来源、计数、警告与字段映射', (tester) async {
      final h = await mount(tester);
      expect(find.text('导入预览'), findsOneWidget);
      expect(find.textContaining('export.csv'), findsOneWidget);
      expect(find.textContaining('共 3 行'), findsOneWidget);
      expect(find.textContaining('col2'), findsWidgets, reason: '警告里应点名未使用的列');
      expect(find.text('字段映射'), findsOneWidget);
      expect(find.text('同名条目'), findsOneWidget);
      // 三个策略都在，默认选「保留现有的」。
      expect(find.text('保留现有的'), findsOneWidget);
      expect(find.text('用导入的内容覆盖'), findsOneWidget);
      expect(find.text('两条都保留'), findsOneWidget);
      expect(h.parses, [null], reason: '首次打开用自动识别，不传映射');
    });

    testWidgets('确认后返回映射与策略，取消返回 null', (tester) async {
      final h = await mount(tester);
      await tester.tap(find.text('开始导入'));
      await tester.pumpAndSettle();
      expect(h.results, hasLength(1));
      expect(h.results.single.strategy, ImportStrategy.skip, reason: '默认保留现有的');
      expect(h.results.single.mapping[ImportField.password], 2);

      final cancelled = await mount(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(cancelled.results, isEmpty, reason: '取消不该返回决定');
    });

    testWidgets('改字段映射会带着新映射回到内核重新解析', (tester) async {
      final h = await mount(tester);
      // 第一个字段（标题）的映射当前为空，选「第 1 列」。
      await tester.tap(find.byType(DropdownButton<int?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('第 1 列').last);
      await tester.pumpAndSettle();

      expect(h.parses.length, greaterThanOrEqualTo(2), reason: '改映射必须重新解析');
      final last = h.parses.last;
      expect(last?[ImportField.title], 0, reason: '新映射要回传内核，而不是在界面里自己算');
    });

    testWidgets('选覆盖策略后确认会带回该策略', (tester) async {
      final h = await mount(tester);
      await tester.tap(find.text('用导入的内容覆盖'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始导入'));
      await tester.pumpAndSettle();
      expect(h.results.single.strategy, ImportStrategy.overwrite);
    });

    testWidgets('没有可导入条目时禁用确认按钮并说明', (tester) async {
      final h = await mount(tester, json: _previewJson(items: 0, totalRows: 0, skipped: 0));
      expect(find.text('这份文件里没有可导入的条目'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始导入'));
      expect(button.onPressed, isNull, reason: '没有条目时不该能点');
      expect(h.results, isEmpty);
    });

    testWidgets('解析失败时展示错误且不能确认', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showImportPreview(
                  context,
                  content: 'raw',
                  sourceName: 'x.csv',
                  parse: (c, {mapping}) async => throw CoreException('invalid_input', '无法识别的 CSV：缺少 password / notes 列'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法识别的 CSV'), findsOneWidget, reason: '解析失败要把原因说清楚');
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始导入'));
      expect(button.onPressed, isNull);
    });
  });
}
