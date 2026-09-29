import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/conflict_models.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/conflicts_page.dart';
import 'package:vaultone/src/ui/theme.dart';
import 'package:vaultone/src/ui/widgets/controls.dart';

ConflictDetail _detail({
  String id = 'c1',
  ConflictState state = ConflictState.pending,
  bool stale = false,
  List<ConflictField> fields = const [
    ConflictField.password,
    ConflictField.username,
  ],
}) {
  const local = ItemData(
    kind: ItemKind.login,
    title: '测试账户',
    username: '本地用户名',
    password: 'local-secret',
  );
  const remote = ItemData(
    kind: ItemKind.login,
    title: '测试账户',
    username: '远端用户名',
    password: 'remote-secret',
  );
  return ConflictDetail(
    id: id,
    itemId: 'item-$id',
    state: state,
    stale: stale,
    fields: fields,
    base: const ConflictVersion(
      revision: 1,
      data: ItemData(
        kind: ItemKind.login,
        title: '测试账户',
        password: 'base-secret',
      ),
    ),
    local: const ConflictVersion(revision: 2, data: local),
    remote: const ConflictVersion(revision: 3, data: remote),
    suggested: local,
  );
}

class _Callbacks {
  List<ConflictDetail> items = [_detail()];
  final history = <bool>[];
  final submissions = <(String, ConflictResolution)>[];
  int refreshes = 0;
  int resolved = 0;
  Object? listError;
  Object? getError;
  Object? resolveError;
  Completer<List<ConflictDetail>>? pendingList;
  final pendingDetails = <String, Completer<ConflictDetail>>{};
  ConflictDetail? refreshed;

  Future<List<ConflictDetail>> list(bool includeHistory) async {
    history.add(includeHistory);
    if (listError != null) throw listError!;
    return pendingList == null ? items : await pendingList!.future;
  }

  Future<ConflictDetail> get(String id) async {
    if (getError != null) throw getError!;
    return pendingDetails[id] == null
        ? items.firstWhere((d) => d.id == id)
        : await pendingDetails[id]!.future;
  }

  Future<ConflictDetail> refresh(String id) async {
    refreshes++;
    return refreshed ?? _detail(id: id);
  }

  Future<void> resolve(String id, ConflictResolution resolution) async {
    if (resolveError != null) throw resolveError!;
    submissions.add((id, resolution));
  }
}

Future<void> _mount(WidgetTester tester, _Callbacks callbacks) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ConflictsPage(
        listConflicts: callbacks.list,
        getConflict: callbacks.get,
        refreshConflict: callbacks.refresh,
        resolveConflict: callbacks.resolve,
        onResolved: () => callbacks.resolved++,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('冲突模型wire与选择约束：不遗漏字段，类型和解决方案仅整条选择', () {
    final detail = ConflictDetail.fromJson(_detail().toJson());
    expect(detail.base!.revision, 1);
    expect(detail.remote.data.password, 'remote-secret');
    expect(detail.fields, [ConflictField.password, ConflictField.username]);
    expect(const ConflictResolution.whole(ConflictSide.remote).toJson(), {
      'mode': 'whole',
      'side': 'remote',
    });
    expect(
      ConflictResolution.fields({ConflictField.password: ConflictSide.local})
          .isValidFor(detail),
      isFalse,
    );
    final choice = ConflictResolution.fields({
      ConflictField.password: ConflictSide.remote,
      ConflictField.username: ConflictSide.local,
    });
    expect(choice.isValidFor(detail), isTrue);
    expect(choice.toJson(), {
      'mode': 'fields',
      'choices': [
        {'field': 'password', 'side': 'remote'},
        {'field': 'username', 'side': 'local'},
      ],
    });
    for (final field in [ConflictField.type, ConflictField.resolution]) {
      expect(
        ConflictResolution.fields({field: ConflictSide.local})
            .isValidFor(_detail(fields: [field])),
        isFalse,
      );
    }
    expect(choice.isValidFor(_detail(stale: true)), isFalse);
    expect(
      choice.isValidFor(_detail(state: ConflictState.resolutionPending)),
      isFalse,
    );
    expect(
      ConflictVersion.fromJson({
        'revision': 4,
        'deleted': true,
        'data': detail.local.data.toJson(),
      }).deleted,
      isTrue,
    );
  });

  testWidgets('列表加载、失败重试和空状态均真实执行回调', (tester) async {
    final callbacks = _Callbacks()
      ..pendingList = Completer<List<ConflictDetail>>();
    await _mount(tester, callbacks);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    callbacks.pendingList!.completeError(CoreException('io', '读取冲突失败'));
    await tester.pumpAndSettle();
    expect(find.text('读取冲突失败'), findsOneWidget);
    callbacks.pendingList = null;
    callbacks.items = [];
    await _tap(tester, find.text('重试'));
    expect(find.text('没有待处理的冲突'), findsOneWidget);
    expect(callbacks.history, [false, false]);
  });

  testWidgets('默认隐藏双方和基础版本的秘密，显式显示后可再次隐藏', (tester) async {
    final callbacks = _Callbacks();
    await _mount(tester, callbacks);
    await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
    expect(find.text('local-secret', skipOffstage: false), findsNothing);
    expect(find.text('remote-secret', skipOffstage: false), findsNothing);
    expect(find.text('base-secret', skipOffstage: false), findsNothing);
    await _tap(tester, find.text('显示敏感内容'));
    expect(find.text('local-secret', skipOffstage: false), findsOneWidget);
    expect(find.text('remote-secret', skipOffstage: false), findsOneWidget);
    await _tap(tester, find.text('隐藏敏感内容'));
    expect(find.text('local-secret', skipOffstage: false), findsNothing);
  });

  for (final side in ConflictSide.values) {
    testWidgets('整条保留${side.name}只本地入队，并转为等待同步', (tester) async {
      final callbacks = _Callbacks();
      await _mount(tester, callbacks);
      await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
      await _tap(
        tester,
        find.text(side == ConflictSide.local ? '保留整条本地' : '保留整条远端'),
      );
      expect(callbacks.submissions.single.$1, 'c1');
      expect(callbacks.submissions.single.$2.toJson(), {
        'mode': 'whole',
        'side': side.name,
      });
      expect(callbacks.resolved, 1);
      expect(find.text('等待同步'), findsOneWidget);
      expect(find.textContaining('选择已保存到本机'), findsOneWidget);
      expect(find.text('保留整条本地'), findsNothing);
      expect(find.text('已同步'), findsNothing);
    });
  }

  testWidgets('逐字段必须全部选择；提交包含准确的双方选择而非整条覆盖', (tester) async {
    final callbacks = _Callbacks();
    await _mount(tester, callbacks);
    await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
    final submit = find.byKey(const ValueKey('resolve-fields'));
    expect(tester.widget<ZoButton>(submit).onPressed, isNull);
    await _tap(tester, find.byKey(const ValueKey('choose-username-local')));
    expect(tester.widget<ZoButton>(submit).onPressed, isNull);
    await _tap(tester, find.byKey(const ValueKey('choose-password-remote')));
    expect(tester.widget<ZoButton>(submit).onPressed, isNotNull);
    await _tap(tester, submit);
    expect(callbacks.submissions.single.$2.choices, {
      ConflictField.username: ConflictSide.local,
      ConflictField.password: ConflictSide.remote,
    });
    expect(callbacks.resolved, 1);
  });

  testWidgets('过期候选不能提交，刷新后才允许选择；服务端再次报过期会重新读取候选', (tester) async {
    final callbacks = _Callbacks()..items = [_detail(stale: true)];
    await _mount(tester, callbacks);
    await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
    expect(find.text('保留整条本地'), findsNothing);
    await _tap(tester, find.text('刷新候选'));
    expect(callbacks.refreshes, 1);
    expect(find.text('保留整条本地'), findsOneWidget);
    callbacks.resolveError = CoreException('conflict_stale', '版本已变化');
    await _tap(tester, find.text('保留整条本地'));
    expect(callbacks.refreshes, 2);
    expect(callbacks.submissions, isEmpty);
    expect(callbacks.resolved, 0);
    expect(find.textContaining('候选已发生变化'), findsOneWidget);
    expect(find.text('显示敏感内容'), findsOneWidget);
  });

  testWidgets('历史只读，类型冲突只能整条选择，详情失败支持重试', (tester) async {
    final callbacks = _Callbacks()
      ..items = [
        _detail(fields: [ConflictField.type]),
      ];
    await _mount(tester, callbacks);
    await _tap(tester, find.text('显示历史记录'));
    expect(callbacks.history.last, isTrue);
    callbacks.getError = CoreException('io', '候选读取失败');
    await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
    expect(find.text('候选读取失败'), findsOneWidget);
    callbacks.getError = null;
    await _tap(tester, find.text('重试'));
    expect(find.textContaining('只能整条保留一方'), findsOneWidget);
    expect(find.byKey(const ValueKey('resolve-fields')), findsNothing);
    callbacks.refreshed = _detail(state: ConflictState.superseded);
    await _tap(tester, find.text('刷新候选'));
    expect(find.text('已被替代'), findsOneWidget);
    expect(find.text('保留整条本地'), findsNothing);
    expect(find.textContaining('历史记录，仅供查看'), findsOneWidget);
  });

  testWidgets('切换候选后晚到的旧详情不能覆盖当前选择', (tester) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final callbacks = _Callbacks()
      ..items = [_detail(id: 'old'), _detail(id: 'new')];
    callbacks.pendingDetails['old'] = Completer<ConflictDetail>();
    await _mount(tester, callbacks);
    await tester.tap(find.byKey(const ValueKey('conflict-old')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('conflict-new')));
    await tester.pumpAndSettle();
    callbacks.pendingDetails['old']!.complete(_detail(id: 'old'));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('保留整条本地'));
    expect(callbacks.submissions.single.$1, 'new');
  });
  test('删除状态wire保留null、false、true三态，缺失旧字段也不推断未删除', () {
    for (final deleted in <bool?>[null, false, true]) {
      final json = {
        'revision': 1,
        'deleted': deleted,
        'data': _detail().local.data.toJson(),
      };
      final version = ConflictVersion.fromJson(json);
      expect(version.deleted, deleted);
      expect(version.toJson()['deleted'], deleted);
      expect(ConflictVersion.fromJson(version.toJson()).deleted, deleted);
    }
    final old = ConflictVersion.fromJson({
      'revision': 1,
      'data': _detail().local.data.toJson(),
    });
    expect(old.deleted, isNull);
    expect(old.toJson()['deleted'], isNull);
  });

  testWidgets('删除冲突界面区分未知旧基线、未删除本地、已删除远端', (tester) async {
    final json = _detail(fields: [ConflictField.deleted]).toJson();
    (json['base'] as Map)['deleted'] = null;
    (json['local'] as Map)['deleted'] = false;
    (json['remote'] as Map)['deleted'] = true;
    final callbacks = _Callbacks()..items = [ConflictDetail.fromJson(json)];
    await _mount(tester, callbacks);
    await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
    expect(find.text('未知（旧基线未记录）'), findsOneWidget);
    expect(find.text('未删除'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('choose-deleted-local')));
    await _tap(tester, find.byKey(const ValueKey('resolve-fields')));
    expect(callbacks.submissions.single.$2.toJson(), {
      'mode': 'fields',
      'choices': [
        {'field': 'deleted', 'side': 'local'},
      ],
    });
  });

  for (final state in [ConflictState.resolved, ConflictState.superseded]) {
    testWidgets('${state.name}历史候选刷新按钮禁用且不会调用修改回调', (tester) async {
      final callbacks = _Callbacks()..items = [_detail(state: state)];
      await _mount(tester, callbacks);
      await _tap(tester, find.byKey(const ValueKey('conflict-c1')));
      final refresh = find.ancestor(
        of: find.text('刷新候选'),
        matching: find.byType(ZoButton),
      );
      expect(tester.widget<ZoButton>(refresh).onPressed, isNull);
      await _tap(tester, find.text('刷新候选'));
      expect(callbacks.refreshes, 0);
      expect(callbacks.submissions, isEmpty);
      expect(find.text('保留整条本地'), findsNothing);
      expect(find.byKey(const ValueKey('resolve-fields')), findsNothing);
    });
  }
}
