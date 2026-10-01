import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/feedback_models.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/ui/screens/feedback_page.dart';
import 'package:vaultone/src/ui/theme.dart';

String _id(int number) =>
    '00000000-0000-4000-8000-${number.toString().padLeft(12, '0')}';

FeedbackSummary _summary(
  int number, {
  FeedbackStatus status = FeedbackStatus.open,
}) => FeedbackSummary(
  id: _id(number),
  category: FeedbackCategory.bug,
  status: status,
  createdAt: 1790812800 + number,
  updatedAt: 1790812800 + number,
  version: 1,
);

FeedbackDetail _detail(
  int number, {
  String content = '测试反馈正文',
  String? contact,
  String? reply,
  FeedbackStatus status = FeedbackStatus.open,
}) => FeedbackDetail(
  summary: _summary(number, status: status),
  content: content,
  contact: contact,
  reply: reply,
);

class _Harness {
  bool allowed = true;
  int idCalls = 0;
  final submissions = <FeedbackSubmission>[];
  final cursors = <int?>[];
  final detailIds = <String>[];
  Future<String> Function()? idHandler;
  Future<FeedbackDetail> Function(FeedbackSubmission)? submitHandler;
  Future<FeedbackPageResult> Function(int?)? listHandler;
  Future<FeedbackDetail> Function(String)? detailHandler;

  Widget app({double textScale = 1}) => MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => page())),
            child: const Text('打开反馈'),
          ),
        ),
      ),
    ),
  );

  FeedbackPage page() => FeedbackPage(
    canContinue: () => allowed,
    newId: () {
      idCalls++;
      return idHandler?.call() ?? Future.value(_id(idCalls));
    },
    submit: (request) {
      submissions.add(request);
      return submitHandler?.call(request) ??
          Future.value(
            FeedbackDetail(
              summary: FeedbackSummary(
                id: request.id,
                category: request.category,
                status: FeedbackStatus.open,
                createdAt: 1790812800,
                updatedAt: 1790812800,
                version: 1,
              ),
              content: request.content,
              contact: request.contact,
            ),
          );
    },
    list: (before) {
      cursors.add(before);
      return listHandler?.call(before) ??
          Future.value(FeedbackPageResult(items: []));
    },
    get: (id) {
      detailIds.add(id);
      return detailHandler?.call(id) ?? Future.value(_detail(1));
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  _Harness harness, {
  Size size = const Size(900, 1100),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(harness.app(textScale: textScale));
  await tester.tap(find.text('打开反馈'));
  await tester.pumpAndSettle();
}

// 不在此等待所有动画：历史/详情的可控 Future 可以保持加载中。
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(Key(key)));

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pump();
}

Future<void> _draft(WidgetTester tester, {String content = '需要帮助'}) async {
  await _enter(tester, 'feedback-content', content);
  await _tapKey(tester, 'feedback-consent');
}

TextField _field(WidgetTester tester, String key) => tester.widget<TextField>(
  find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)),
);

void main() {
  testWidgets('必须显式同意且正文非空，按所选类型提交规范化内容', (tester) async {
    final h = _Harness();
    await _mount(tester, h);
    expect(find.text('客服可以读取反馈'), findsOneWidget);
    expect(find.textContaining('请勿填写密码、Secret Key、恢复码'), findsOneWidget);
    expect(h.cursors, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('feedback-submit')))
          .onPressed,
      isNull,
    );
    await _enter(tester, 'feedback-content', '  \n  ');
    await _tapKey(tester, 'feedback-submit');
    expect(h.idCalls, 0);
    await _tapKey(tester, 'feedback-consent');
    await _tapKey(tester, 'feedback-submit');
    expect(find.text('请填写反馈正文'), findsOneWidget);
    expect(h.idCalls, 0);

    await _enter(tester, 'feedback-content', '  导入失败\n保留换行  ');
    await _enter(tester, 'feedback-contact', '  contact@example.test  ');
    await _tap(tester, find.byType(DropdownButtonFormField<FeedbackCategory>));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('功能建议').last);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    expect(h.submissions, hasLength(1));
    final request = h.submissions.single;
    expect(request.category, FeedbackCategory.suggestion);
    expect(request.content, '导入失败\n保留换行');
    expect(request.contact, 'contact@example.test');
    expect(request.toJson()['consent'], isTrue);
    expect(find.text('提交成功'), findsOneWidget);
    expect(find.byKey(const Key('feedback-content')), findsNothing);
  });

  testWidgets('正文按 UTF-16 限 4000，联系方式限 200，超限不生成编号', (tester) async {
    final h = _Harness();
    await _mount(tester, h);
    final body = List.filled(2000, String.fromCharCode(0x1F600)).join();
    await _draft(tester, content: '${body}a');
    await _enter(tester, 'feedback-contact', List.filled(201, 'a').join());
    await _tapKey(tester, 'feedback-submit');
    expect(find.text('正文最多 4000 个 UTF-16 代码单元'), findsOneWidget);
    expect(find.text('联系方式最多 200 个 UTF-16 代码单元'), findsOneWidget);
    expect(h.idCalls, 0);
    expect(h.submissions, isEmpty);

    await _enter(tester, 'feedback-content', body);
    await _enter(tester, 'feedback-contact', List.filled(200, 'a').join());
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    expect(h.submissions.single.content.length, 4000);
    expect(h.submissions.single.contact!.length, 200);
    expect(h.idCalls, 1);
  });

  testWidgets('失败冻结表单，切到空历史后仍以同一不可变请求和编号重试', (tester) async {
    final h = _Harness();
    h.submitHandler = (request) async {
      if (h.submissions.length == 1) {
        throw CoreException('network', '不得显示的内部地址');
      }
      return _detail(1, content: request.content);
    };
    await _mount(tester, h);
    await _draft(tester, content: '原始内容');
    await _enter(tester, 'feedback-contact', '   ');
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    expect(find.text('网络连接异常，请检查连接后重试。'), findsOneWidget);
    expect(find.textContaining('尚未确认提交结果'), findsOneWidget);
    expect(find.text('不得显示的内部地址'), findsNothing);
    expect(_field(tester, 'feedback-content').readOnly, isTrue);
    expect(_field(tester, 'feedback-contact').readOnly, isTrue);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('feedback-consent')))
          .onChanged,
      isNull,
    );

    await _tapKey(tester, 'feedback-history-tab');
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无反馈记录'), findsOneWidget);
    await _tapKey(tester, 'feedback-write-tab');
    expect(_field(tester, 'feedback-content').controller!.text, '原始内容');
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    expect(h.idCalls, 1);
    expect(h.submissions, hasLength(2));
    expect(identical(h.submissions[0], h.submissions[1]), isTrue);
    expect(h.submissions.first.contact, isNull);
    expect(find.text('提交成功'), findsOneWidget);
  });

  testWidgets('放弃未知提交须显式确认，提示可能已提交且不会自动重新发送', (tester) async {
    final h = _Harness()
      ..submitHandler = (_) async => throw CoreException('network', '内部诊断');
    await _mount(tester, h);
    await _draft(tester, content: '第一条');
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'feedback-abandon');
    expect(find.textContaining('本次反馈可能已经提交'), findsOneWidget);
    expect(find.text('先看历史'), findsOneWidget);
    expect(_field(tester, 'feedback-content').readOnly, isTrue);
    await _tap(tester, find.text('取消放弃'));
    expect(find.byKey(const Key('feedback-confirm-abandon')), findsNothing);
    expect(h.idCalls, 1);
    await _tapKey(tester, 'feedback-abandon');
    await _tapKey(tester, 'feedback-confirm-abandon');
    expect(_field(tester, 'feedback-content').controller!.text, isEmpty);
    expect(_field(tester, 'feedback-content').readOnly, isFalse);
    expect(h.idCalls, 1);
    expect(h.submissions, hasLength(1));
    await _draft(tester, content: '主动新建的第二条');
    await _tapKey(tester, 'feedback-submit');
    await tester.pumpAndSettle();
    expect(h.idCalls, 2);
    expect(h.submissions.last.id, isNot(h.submissions.first.id));
    expect(h.submissions.last.content, '主动新建的第二条');
  });

  testWidgets('历史游标分页、失败保留已有页、原游标重试和刷新', (tester) async {
    final h = _Harness();
    var moreCalls = 0;
    h.listHandler = (before) async {
      if (before == null) {
        return FeedbackPageResult(items: [_summary(1)], nextBefore: 40);
      }
      expect(before, 40);
      if (++moreCalls == 1) throw CoreException('network', '内部诊断');
      return FeedbackPageResult(items: [_summary(1), _summary(2)]);
    };
    await _mount(tester, h);
    await _tapKey(tester, 'feedback-history-tab');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'feedback-more');
    await tester.pumpAndSettle();
    expect(find.byKey(Key('feedback-item-${_id(1)}')), findsOneWidget);
    expect(find.text('网络连接异常，请检查连接后重试。'), findsOneWidget);
    await _tap(tester, find.text('重试读取历史'));
    await tester.pumpAndSettle();
    expect(h.cursors, [null, 40, 40]);
    expect(find.byKey(Key('feedback-item-${_id(1)}')), findsOneWidget);
    expect(find.byKey(Key('feedback-item-${_id(2)}')), findsOneWidget);
    expect(find.byKey(const Key('feedback-more')), findsNothing);
    await _tapKey(tester, 'feedback-refresh');
    await tester.pumpAndSettle();
    expect(h.cursors, [null, 40, 40, null]);
    expect(find.byKey(Key('feedback-item-${_id(2)}')), findsNothing);
    h.allowed = false;
    await _tapKey(tester, 'feedback-refresh');
    expect(h.cursors, [null, 40, 40, null]);
    expect(find.text('反馈页面已失效，请解锁并重新进入。'), findsOneWidget);
  });

  testWidgets('详情显示状态及最近回复，缺回复为空态且 HTML 与链接只作纯文本', (tester) async {
    const reply = '<b>仅作为文字</b>\n[查看](https://example.test)';
    final h = _Harness();
    h.listHandler = (_) async => FeedbackPageResult(
      items: [
        _summary(1),
        _summary(2, status: FeedbackStatus.resolved),
      ],
    );
    h.detailHandler = (id) async => id == _id(1)
        ? _detail(1)
        : _detail(
            2,
            status: FeedbackStatus.resolved,
            content: '第二条正文',
            contact: 'user@example.test',
            reply: reply,
          );
    await _mount(tester, h);
    await _tapKey(tester, 'feedback-history-tab');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'feedback-item-${_id(1)}');
    await tester.pumpAndSettle();
    expect(find.text('暂时没有回复。'), findsOneWidget);
    await _tapKey(tester, 'feedback-back-history');
    await _tapKey(tester, 'feedback-item-${_id(2)}');
    await tester.pumpAndSettle();
    expect(find.text('问题反馈 · 已处理'), findsOneWidget);
    expect(find.text('第二条正文'), findsOneWidget);
    expect(find.text('user@example.test'), findsOneWidget);
    expect(find.text('客服最近回复'), findsOneWidget);
    expect(find.text(reply), findsOneWidget);
    expect(tester.widget<Text>(find.text(reply)).textSpan, isNull);
    await _tapKey(tester, 'feedback-back-history');
    expect(h.cursors, [null]);
    h.allowed = false;
    await _tapKey(tester, 'feedback-item-${_id(1)}');
    expect(h.detailIds, [_id(1), _id(2)]);
  });

  testWidgets('旧历史响应及已离开详情的旧响应不能覆盖新结果', (tester) async {
    final oldList = Completer<FeedbackPageResult>();
    final oldDetail = Completer<FeedbackDetail>();
    final h = _Harness();
    h.listHandler = (_) => h.cursors.length == 1
        ? oldList.future
        : Future.value(FeedbackPageResult(items: [_summary(2)]));
    h.detailHandler = (_) => h.detailIds.length == 1
        ? oldDetail.future
        : Future.value(_detail(2, content: '最新详情'));
    await _mount(tester, h);
    await _tapKey(tester, 'feedback-history-tab');
    await _tapKey(tester, 'feedback-refresh');
    await tester.pumpAndSettle();
    oldList.complete(FeedbackPageResult(items: [_summary(1)]));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('feedback-item-${_id(1)}')), findsNothing);
    expect(find.byKey(Key('feedback-item-${_id(2)}')), findsOneWidget);
    await _tapKey(tester, 'feedback-item-${_id(2)}');
    await _tapKey(tester, 'feedback-back-history');
    await _tapKey(tester, 'feedback-item-${_id(2)}');
    await tester.pumpAndSettle();
    oldDetail.complete(_detail(2, content: '过时详情'));
    await tester.pumpAndSettle();
    expect(find.text('最新详情'), findsOneWidget);
    expect(find.text('过时详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭销毁草稿，未挂载页面不展示晚到提交，重新进入为空', (tester) async {
    final result = Completer<FeedbackDetail>();
    final h = _Harness()..submitHandler = (_) => result.future;
    await _mount(tester, h);
    await _draft(tester, content: '关闭前的正文');
    await _tapKey(tester, 'feedback-submit');
    expect(h.submissions, hasLength(1));
    await _tapKey(tester, 'feedback-close');
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackPage), findsNothing);
    result.complete(_detail(1, content: '晚到正文'));
    await tester.pumpAndSettle();
    expect(find.text('晚到正文'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('打开反馈'));
    await tester.pumpAndSettle();
    expect(_field(tester, 'feedback-content').controller!.text, isEmpty);
    expect(find.text('原样重试'), findsNothing);
    expect(h.idCalls, 1);
  });

  testWidgets('生成编号期间锁定，晚到编号不能触发提交或恢复本页内容', (tester) async {
    final id = Completer<String>();
    final h = _Harness()..idHandler = () => id.future;
    await _mount(tester, h);
    await _draft(tester, content: '锁定前正文');
    final controller = _field(tester, 'feedback-content').controller!;
    await _tapKey(tester, 'feedback-submit');
    expect(h.idCalls, 1);
    h.allowed = false;
    id.complete(_id(1));
    await tester.pumpAndSettle();
    expect(h.submissions, isEmpty);
    expect(controller.text, isEmpty);
    expect(find.text('反馈页面已失效，请解锁并重新进入。'), findsOneWidget);
    h.allowed = true;
    tester.element(find.byType(FeedbackPage)).markNeedsBuild();
    await tester.pump();
    expect(find.byKey(const Key('feedback-content')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('锁定清除草稿和历史，并拒绝所有同时晚到的提交列表详情', (tester) async {
    final submission = Completer<FeedbackDetail>();
    final listing = Completer<FeedbackPageResult>();
    final detail = Completer<FeedbackDetail>();
    final h = _Harness();
    h.submitHandler = (_) => submission.future;
    h.detailHandler = (_) => detail.future;
    h.listHandler = (_) => h.cursors.length == 1
        ? Future.value(FeedbackPageResult(items: [_summary(1)]))
        : listing.future;
    await _mount(tester, h);
    await _draft(tester, content: '锁定即清除的草稿');
    final controller = _field(tester, 'feedback-content').controller!;
    await _tapKey(tester, 'feedback-submit');
    await _tapKey(tester, 'feedback-history-tab');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'feedback-refresh');
    await _tapKey(tester, 'feedback-item-${_id(1)}');
    h.allowed = false;
    tester.element(find.byType(FeedbackPage)).markNeedsBuild();
    await tester.pump();
    expect(controller.text, isEmpty);
    submission.complete(_detail(1, content: '晚到提交'));
    listing.complete(FeedbackPageResult(items: [_summary(2)]));
    detail.complete(_detail(1, content: '晚到详情', reply: '晚到客服回复'));
    await tester.pumpAndSettle();
    expect(find.text('晚到提交'), findsNothing);
    expect(find.text('晚到详情'), findsNothing);
    expect(find.text('晚到客服回复'), findsNothing);
    expect(find.byKey(Key('feedback-item-${_id(2)}')), findsNothing);
    expect(find.text('反馈页面已失效，请解锁并重新进入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误只按稳定 code 展示安全中文，未知异常不泄露 message', (tester) async {
    Object error = CoreException('network', 'PRIVATE_SERVER_DIAGNOSTIC');
    final h = _Harness()..listHandler = (_) async => throw error;
    await _mount(tester, h);
    await _tapKey(tester, 'feedback-history-tab');
    await tester.pumpAndSettle();
    const messages = {
      'network': '网络连接异常，请检查连接后重试。',
      'unauthorized': '云会话已失效，请重新登录后再试。',
      'forbidden': '当前设备无权访问反馈，请检查设备授权。',
      'invalid_input': '反馈格式不符合要求，请检查类型和长度。',
      'conflict': '此提交编号已被使用，请先查看历史确认结果。',
      'not_found': '反馈不存在或已到期，请刷新历史记录。',
      'rate_limited': '提交过于频繁或已达数量上限，请稍后再试。',
      'service_unavailable': '反馈服务暂时不可用，请稍后重试。',
      'unknown_code': '暂时无法完成操作，请稍后重试。',
    };
    for (final entry in messages.entries) {
      error = CoreException(entry.key, 'PRIVATE_SERVER_DIAGNOSTIC');
      await _tapKey(tester, 'feedback-refresh');
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.textContaining('PRIVATE_SERVER_DIAGNOSTIC'), findsNothing);
    }
    error = StateError('PRIVATE_SERVER_DIAGNOSTIC');
    await _tapKey(tester, 'feedback-refresh');
    await tester.pumpAndSettle();
    expect(find.text('暂时无法完成操作，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('PRIVATE_SERVER_DIAGNOSTIC'), findsNothing);
  });

  testWidgets('窄屏放大文字无溢出，Material 按钮支持键盘且请求前检查门禁', (tester) async {
    final h = _Harness();
    await _mount(tester, h, size: const Size(320, 700), textScale: 1.3);
    await _draft(tester, content: '窄屏也可以提交反馈');
    await _enter(tester, 'feedback-contact', 'contact@example.test');
    final submit = find.byKey(const Key('feedback-submit'));
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    Focus.of(tester.element(find.text('提交反馈'))).requestFocus();
    await tester.pump();
    // 不重建，模拟按钮已可用后会话门禁立即失效。
    h.allowed = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.idCalls, 0);
    expect(h.submissions, isEmpty);
    expect(find.text('反馈页面已失效，请解锁并重新进入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
