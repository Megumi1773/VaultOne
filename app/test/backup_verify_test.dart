import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/backup_dialog.dart';
import 'package:vaultone/src/ui/screens/onboarding.dart';
import 'package:vaultone/src/ui/theme.dart';
import 'package:vaultone/src/ui/widgets/controls.dart';

/// 只覆写核对路径的测试替身：真实 `AppState` 的核对会走 Rust 桥，纯 widget 测试无桥。
class _FakeState extends AppState {
  _FakeState({this.failWith, this.canonical});

  final String? failWith;
  final ({String secretKey, String recoveryCode})? canonical;

  @override
  Future<({String secretKey, String recoveryCode})> verifyRecoveryMaterials({
    required String secretKey,
    required String recoveryCode,
  }) async {
    if (failWith != null) throw CoreException(failWith!, '核对失败');
    return canonical ?? (secretKey: secretKey, recoveryCode: recoveryCode);
  }

  @override
  Future<String> confirmSecretKey(String candidate) async {
    if (failWith != null) throw CoreException(failWith!, '核对失败');
    return candidate;
  }

  @override
  Future<void> recordBackup(String kind) async {
    lastBackupAt = 1760000000;
    lastBackupKind = kind;
  }
}

Future<_FakeState> _pump(
  WidgetTester tester,
  Widget child, {
  String? failWith,
  ({String secretKey, String recoveryCode})? canonical,
}) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _FakeState(failWith: failWith, canonical: canonical);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    home: Scaffold(body: AppScope(state: state, child: child)),
  ));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  return state;
}

bool _buttonEnabled(WidgetTester tester, String label) =>
    tester.widget<ZoButton>(find.widgetWithText(ZoButton, label)).onPressed != null;

/// `ZoTextField` 的 label 渲染在输入框之外，因此按索引定位内部 `TextField`。
Finder _input(int index) => find.descendant(of: find.byType(ZoTextField), matching: find.byType(TextField)).at(index);

const _enrollment = Enrollment(
  accountId: 'acct-1',
  email: 'yg@example.com',
  secretKey: 'V1-2H7K9M-3PQ4RS-5TVW6X-7YZ012-3H7K9M-3PQ4RS-5TVW6X',
  recoveryCode: 'R1-2H7K-9M3P-Q4RS-5TVW-6X7Y-Z012-3H7K-9M3P-Q4RS-5TVW-6X7Y-Z012',
);

void main() {
  testWidgets('恢复套件页：核对通过前不能勾选确认、不能进入保险库', (tester) async {
    var done = false;
    await _pump(tester, RecoveryKitView(enrollment: _enrollment, onDone: () async => done = true));

    expect(find.text('逐字节核对 Secret Key'), findsOneWidget);
    expect(find.textContaining('大小写、连字符与 I/L/O'), findsOneWidget);

    // 未核对：确认框禁用，进入保险库按钮禁用
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    expect(_buttonEnabled(tester, '进入保险库'), isFalse);

    await tester.tap(find.text('进入保险库'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(done, isFalse, reason: '核对未通过不得进入保险库');
  });

  testWidgets('恢复套件页：Secret Key 核对通过后才解锁确认', (tester) async {
    await _pump(tester, RecoveryKitView(enrollment: _enrollment, onDone: () async {}));

    await tester.enterText(_input(0), _enrollment.secretKey);
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对'));
    await tester.pumpAndSettle();

    expect(find.text('与本机保存的 Secret Key 逐字节一致。'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNotNull, reason: '核对通过后允许勾选');
  });

  testWidgets('恢复套件页：核对不一致给出逐组核对提示且保持锁定', (tester) async {
    await _pump(tester, RecoveryKitView(enrollment: _enrollment, onDone: () async {}), failWith: 'secret_key_mismatch');

    await tester.enterText(
      _input(0),
      'V1-000000-000000-000000-000000-000000-000000-000000',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对'));
    await tester.pumpAndSettle();

    expect(find.textContaining('与本机保存的 Secret Key 不一致'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
  });

  testWidgets('备份管理对话框：未核对时重新导出按钮全部禁用', (tester) async {
    await _pump(tester, const BackupManagerDialog());

    expect(find.text('密钥与备份'), findsOneWidget);
    expect(find.text('从未记录'), findsOneWidget);
    expect(find.textContaining('服务端备份记录端点未实现'), findsOneWidget);

    for (final label in ['恢复套件（PDF）', '备份卡（PNG 700×900）', '查看 Secret Key']) {
      expect(_buttonEnabled(tester, label), isFalse, reason: '$label 未核对不得可用');
    }
  });

  testWidgets('备份管理对话框：按稳定错误码区分恢复码格式与 Secret Key 不一致', (tester) async {
    await _pump(tester, const BackupManagerDialog(), failWith: 'invalid_input');
    await tester.enterText(_input(0), _enrollment.secretKey);
    await tester.enterText(_input(1), 'R1-XXXX');
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对'));
    await tester.pumpAndSettle();
    expect(find.textContaining('恢复码格式不正确'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, const BackupManagerDialog(), failWith: 'secret_key_mismatch');
    await tester.enterText(_input(0), _enrollment.secretKey);
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对'));
    await tester.pumpAndSettle();
    expect(find.textContaining('注意易混字符 I/L/O'), findsOneWidget);
  });

  testWidgets('备份管理对话框：核对通过后三个导出入口同时可用', (tester) async {
    await _pump(
      tester,
      const BackupManagerDialog(),
      canonical: (secretKey: _enrollment.secretKey, recoveryCode: _enrollment.recoveryCode),
    );
    await tester.enterText(_input(0), _enrollment.secretKey);
    await tester.enterText(_input(1), _enrollment.recoveryCode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对'));
    await tester.pumpAndSettle();

    expect(find.textContaining('逐字节一致；恢复码格式有效'), findsWidgets);
    for (final label in ['恢复套件（PDF）', '备份卡（PNG 700×900）', '查看 Secret Key']) {
      expect(_buttonEnabled(tester, label), isTrue, reason: '$label 核对通过后应可用');
    }
  });
}
