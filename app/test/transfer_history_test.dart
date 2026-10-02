import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/transfer_history_dialog.dart';
import 'package:vaultone/src/ui/theme.dart';

TransferRecord _rec({
  int at = 1700000000,
  TransferDirection direction = TransferDirection.import,
  String format = 'chrome',
  String source = 'export.csv',
  int added = 3,
  int updated = 0,
  int duplicates = 1,
  int skipped = 2,
  int bytes = 128,
}) =>
    (
      at: at,
      direction: direction,
      format: format,
      source: source,
      added: added,
      updated: updated,
      duplicates: duplicates,
      skipped: skipped,
      bytes: bytes,
    );

Future<List<TransferRecord>> _mount(
  WidgetTester tester, {
  required List<TransferRecord> history,
  List<int>? clearCalls,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  var current = history;
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: TransferHistoryDialog(
        load: () async => current,
        clear: () async {
          clearCalls?.add(1);
          current = const [];
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return current;
}

void main() {
  group('TransferRecord 解析', () {
    test('缺字段按默认值处理，方向认不出时按导入', () {
      final r = transferRecordFromJson(const {'format': 'csv'});
      expect(r.direction, TransferDirection.import);
      expect(r.source, '');
      expect(r.bytes, 0);
      expect(r.at, 0);
    });

    test('wire 值与内核一致', () {
      expect(TransferDirection.import.wire, 'import');
      expect(TransferDirection.export.wire, 'export');
      expect(TransferDirection.parse('export'), TransferDirection.export);
      expect(TransferDirection.parse('import'), TransferDirection.import);
      expect(TransferDirection.parse(null), TransferDirection.import);
    });

    test('完整字段正常解析', () {
      final r = transferRecordFromJson(const {
        'at': 1700000000,
        'direction': 'export',
        'format': 'wljbak',
        'source': '',
        'added': 0,
        'updated': 0,
        'duplicates': 0,
        'skipped': 0,
        'bytes': 4096,
      });
      expect(r.direction, TransferDirection.export);
      expect(r.format, 'wljbak');
      expect(r.bytes, 4096);
    });
  });

  group('历史对话框', () {
    testWidgets('空历史给出空态而不是空白', (tester) async {
      await _mount(tester, history: const []);
      expect(find.text('还没有导入导出记录'), findsOneWidget);
      // 没有记录时不显示清空按钮。
      expect(find.text('清空历史'), findsNothing);
    });

    testWidgets('按内核给的顺序展示，导入与导出文案不同', (tester) async {
      await _mount(tester, history: [
        _rec(at: 1700000000, direction: TransferDirection.import, format: 'chrome', source: 'export.csv'),
        _rec(at: 1699990000, direction: TransferDirection.export, format: 'wljbak', source: '', bytes: 4096),
      ]);
      expect(find.text('导入'), findsOneWidget);
      expect(find.text('导出'), findsOneWidget);
      expect(find.text('chrome'), findsOneWidget);
      expect(find.text('wljbak'), findsOneWidget);
      expect(find.textContaining('export.csv'), findsOneWidget);
      // 导出没有来源，要如实说明而不是留空。
      expect(find.text('未记录来源'), findsOneWidget);
    });

    testWidgets('计数与体积逐条展示', (tester) async {
      await _mount(tester, history: [_rec(added: 3, updated: 1, duplicates: 2, skipped: 4, bytes: 512)]);
      expect(find.text('新增 3，覆盖 1，重复 2，跳过 4'), findsOneWidget);
      expect(find.text('512 字节'), findsOneWidget);
    });

    testWidgets('清空要二次确认，取消则不动', (tester) async {
      final calls = <int>[];
      await _mount(tester, history: [_rec()], clearCalls: calls);
      await tester.tap(find.text('清空历史'));
      await tester.pumpAndSettle();
      expect(find.textContaining('条目数据不受影响'), findsOneWidget, reason: '破坏性操作要说清后果');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('chrome'), findsOneWidget, reason: '取消后列表还在');
    });

    testWidgets('确认后清空并刷新为空态', (tester) async {
      final calls = <int>[];
      await _mount(tester, history: [_rec()], clearCalls: calls);
      await tester.tap(find.text('清空历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空历史').last);
      await tester.pumpAndSettle();
      expect(calls, [1]);
      expect(find.text('还没有导入导出记录'), findsOneWidget);
    });
  });
}
