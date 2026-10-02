import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/field_kind.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/item_detail.dart' show FieldImagePreview, ImageLoadFailure;
import 'package:vaultone/src/ui/theme.dart';

void main() {
  group('CustomField 的 kind 序列化', () {
    test('缺 kind 的旧数据按文本处理', () {
      final f = CustomField.fromJson(const {'label': 'PIN', 'value': '1234', 'sensitive': true});
      expect(f.kind, FieldKind.text, reason: '旧库没有这个键，不能崩也不能猜成别的类型');
      expect(f.sensitive, isTrue);
    });

    test('已知 kind 正常往返，未知 kind 回退文本', () {
      for (final kind in FieldKind.values) {
        final f = CustomField(label: 'x', value: 'v', kind: kind);
        expect(CustomField.fromJson(f.toJson()).kind, kind);
        expect(f.toJson()['kind'], kind.wire, reason: 'wire 值要与内核 serde 名一致');
      }
      expect(FieldKind.parse('image'), FieldKind.image);
      expect(FieldKind.parse('date'), FieldKind.date);
      expect(FieldKind.parse('future-kind'), FieldKind.text);
      expect(FieldKind.parse(null), FieldKind.text);
    });

    test('sensitive 与 kind 正交：图片也可以是敏感字段', () {
      final f = CustomField(label: '证件照', value: '/a.jpg', sensitive: true, kind: FieldKind.image);
      final back = CustomField.fromJson(f.toJson());
      expect(back.sensitive, isTrue);
      expect(back.kind, FieldKind.image);
    });
  });

  group('日期展示辅助', () {
    test('formatDateValue 产出内核规范化格式', () {
      expect(formatDateValue(DateTime(2026, 10, 2)), '2026-10-02');
      expect(formatDateValue(DateTime(2026, 1, 2)), '2026-01-02', reason: '要补零');
    });

    test('parseDateValue 接受三种分隔符', () {
      for (final raw in ['2026-10-02', '2026/10/02', '2026.10.02', ' 2026-10-02 ']) {
        expect(parseDateValue(raw), DateTime(2026, 10, 2), reason: raw);
      }
    });

    test('parseDateValue 对认不出的输入返回 null，不抛异常', () {
      for (final raw in ['', '下个月', '2026-10', '2026/10-02', 'abcd-10-02', '2026-13-02', '2026-10-32']) {
        expect(parseDateValue(raw), isNull, reason: raw);
      }
    });

    test('format 与 parse 往返一致', () {
      final d = DateTime(2026, 10, 2);
      expect(parseDateValue(formatDateValue(d)), d);
    });
  });

  group('图片地址判定', () {
    test('只有 http/https 算远程', () {
      expect(isRemoteImage('https://example.com/a.png'), isTrue);
      expect(isRemoteImage('HTTP://example.com/a.png'), isTrue, reason: '大小写不敏感');
      expect(isRemoteImage('  https://example.com/a.png  '), isTrue);
      expect(isRemoteImage('/home/me/a.png'), isFalse);
      expect(isRemoteImage('C:\\Users\\me\\a.png'), isFalse);
      expect(isRemoteImage('file:///a.png'), isFalse, reason: 'file:// 走本地分支');
    });
  });

  group('图片字段预览', () {
    Future<void> mount(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Center(child: child)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('失败态显示图标与说明，而不是留白', (tester) async {
      await mount(tester, const ImageLoadFailure());
      expect(find.text('图片无法加载'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    });

    testWidgets('远程地址拉不到时 errorBuilder 接到失败态', (tester) async {
      // 测试环境下网络请求必然失败，正好覆盖「远程地址加载失败」这条端到端路径。
      await mount(tester, const FieldImagePreview(value: 'https://127.0.0.1:1/none.png'));
      expect(find.text('图片无法加载'), findsOneWidget);
    });
  });
}
