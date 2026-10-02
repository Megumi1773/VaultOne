import 'dart:async';
import 'dart:io';

// 使用 file_selector 已有的官方平台测试接口。
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/app.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/config.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/core/feedback_models.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/home.dart';
import 'package:vaultone/src/ui/screens/item_editor.dart';
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/theme.dart';
import 'package:vaultone/src/rust/api/browser.dart' as rb;
import 'package:vaultone/src/rust/api/vault.dart' as rv;
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';

/// 只替换 FRB 边界：测试仍执行真实 AppState、门面与 Navigator。
class _Bridge implements RustLibApi {
  final settings = <String, String>{};
  int networkCalls = 0;
  Completer<String>? pendingItems;
  Completer<void>? pendingLock;
  Completer<String>? pendingCsv;
  Completer<String>? pendingFeedback;

  @override
  Future<String> crateApiFeedbackListFeedback({int? before, required int limit}) {
    networkCalls++;
    return pendingFeedback?.future ?? Future.value('{"items":[],"next_before":null}');
  }

  @override
  Future<String> crateApiFeedbackSubmitFeedback({required String requestJson}) {
    networkCalls++;
    return pendingFeedback!.future;
  }

  @override
  Future<String> crateApiFeedbackGetFeedback({required String id}) {
    networkCalls++;
    return pendingFeedback!.future;
  }

  @override
  Future<List<rb.BrowserClientDto>> crateApiBrowserListBrowserClients() async => [];

  @override
  Future<String> crateApiVaultExportCsv() => pendingCsv!.future;

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async => settings[key];
  @override
  Future<void> crateApiVaultSetSetting({required String key, required String value}) async { settings[key] = value; }
  @override
  Future<rv.VaultStatus> crateApiVaultStatus() async => const rv.VaultStatus(initialized: true, unlocked: false, accountId: 'existing', quickUnlockEnabled: false, pendingLogin: false);
  @override
  Future<void> crateApiVaultOpenVault({required String path}) async {}
  @override
  Future<void> crateApiLoggingInitLogging({required String logDir, required bool verbose}) async {}
  @override
  Future<void> crateApiLoggingLogEvent({required String level, required String message}) async {}
  @override
  Future<void> crateApiVaultUnlock({required String password, required String secretKey}) async {}
  @override
  Future<void> crateApiVaultLock() => pendingLock?.future ?? Future.value();
  @override
  Future<String> crateApiVaultListItems() => pendingItems?.future ?? Future.value('[]');
  @override
  Future<String> crateApiVaultListTrash() async => '[]';
  @override
  Future<String> crateApiVaultCategoryTree() async => '[]';
  @override
  Future<rv.AccountInfo> crateApiVaultAccountInfo() async => rv.AccountInfo(accountId: 'existing', email: 'test@example.com', kdfSummary: 'test', pendingChanges: BigInt.zero, itemCount: BigInt.zero);
  @override
  Future<RemoteStatusDto?> crateApiSyncRemoteStatus() async => RemoteStatusDto(serverUrl: AppConfig.defaultServerUrl, deviceId: 'device', deviceName: 'test', pending: BigInt.zero);
  @override
  Future<rv.EnrollmentDto?> crateApiCloudAccountPendingEnrollment() async => null;
  @override
  Future<String?> crateApiCloudAccountPendingOperation() async => null;
  @override
  Future<SyncReportDto> crateApiSyncSyncNow() async {
    networkCalls++;
    return const SyncReportDto(pulled: 0, pushed: 0, merged: 0, conflicts: 0, credentialsUpdated: false);
  }
  @override
  Future<void> crateApiSyncPingServer({required String serverUrl}) async { networkCalls++; }
  @override
  Future<void> crateApiSyncConfigureDevelopmentHttp({String? serverUrl}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 保留实际导出与 File 写入，只延迟系统保存位置对话框。
class _SaveDialog extends FileSelectorPlatform {
  final result = Completer<FileSaveLocation?>();
  int requests = 0;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) {
    requests++;
    return result.future;
  }
}

Future<AppState> _openCsvExport(WidgetTester tester, _Bridge bridge, _SaveDialog dialog) async {
  final oldPlatform = FileSelectorPlatform.instance;
  FileSelectorPlatform.instance = dialog;
  addTearDown(() => FileSelectorPlatform.instance = oldPlatform);
  PackageInfo.setMockInitialValues(appName: 'VaultOne', packageName: 'vaultone', version: '1', buildNumber: '1', buildSignature: '');
  final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
  addTearDown(state.dispose);
  bridge.pendingCsv = Completer<String>();
  await tester.pumpWidget(AppScope(state: state, child: MaterialApp(
    theme: buildTheme(Brightness.light),
    home: const Scaffold(body: SettingsPage()),
  )));
  await tester.pumpAndSettle();
  final row = find.ancestor(of: find.text('导出明文 CSV'), matching: find.byType(Row)).first;
  final export = find.descendant(of: row, matching: find.text('导出'));
  await tester.ensureVisible(export);
  await tester.pumpAndSettle();
  await tester.tap(export);
  await tester.pumpAndSettle();
  await tester.tap(find.text('仍要导出'));
  await tester.pumpAndSettle();
  expect(dialog.requests, 0, reason: '必须等真实门面的 CSV 导出完成才打开保存对话框');
  bridge.pendingCsv!.complete('title,password\n账户,测试秘密');
  await tester.pumpAndSettle();
  expect(dialog.requests, 1);
  return state;
}

/// pumpAndSettle 只等待 Flutter 帧；真实 File 的打开/刷新/关闭还需让出事件循环。
Future<void> _waitForIoMessage(WidgetTester tester, String message) async {
  for (var i = 0; i < 200 && find.textContaining(message).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(find.textContaining(message), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Bridge bridge;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/local_auth'), (_) async => false,
    );
    bridge = _Bridge();
    RustLib.initMock(api: bridge);
  });
  tearDown(() => RustLib.dispose());

  testWidgets('现有保险库缺失同意：init、解锁、即时和周期同步均不联网；同意后恢复同步', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.init('unused', 'unused');
    expect(state.phase, AppPhase.locked);
    expect(state.privacyAccepted, isFalse);
    expect(bridge.networkCalls, 0);
    await state.unlock('password', secretKey: 'key');
    expect(state.phase, AppPhase.unlocked);
    await state.syncNow();
    state.scheduleSync(immediate: true);
    await tester.pump(const Duration(milliseconds: 20));
    expect(bridge.networkCalls, 0);
    await tester.pump(const Duration(minutes: 6));
    expect(state.phase, AppPhase.unlocked);
    expect(bridge.networkCalls, 0);
    await state.acceptPrivacy();
    await tester.pump(const Duration(milliseconds: 20));
    expect(bridge.networkCalls, 1);
    await state.lock();
  });

  test('反馈真实门面在锁定后拒绝晚到结果，状态层拒绝新请求', () async {
    bridge.settings['privacy_consent'] = VaultApi.privacyVersion;
    bridge.pendingFeedback = Completer<String>();
    final state = AppState()..phase = AppPhase.unlocked;
    addTearDown(state.dispose);
    final pending = state.listFeedback(null);
    final check = expectLater(pending, throwsA(isA<CoreException>()));
    await Future<void>.delayed(Duration.zero);
    expect(bridge.networkCalls, 1);
    VaultApi.invalidateSession();
    state.phase = AppPhase.locked;
    bridge.pendingFeedback!.complete('{"items":[],"next_before":null}');
    await check;
    await expectLater(state.getFeedback('id'), throwsA(isA<CoreException>()));
    expect(bridge.networkCalls, 1);
  });

  test('全部远程门面缺失或旧版本同意时拒绝，不能绕过状态层', () async {
    final requests = <Future<Object?> Function()>[
      () => VaultApi.pingServer('https://test.invalid'),
      () => VaultApi.connectRegister('url', 'device'),
      () => VaultApi.loginExisting('url', 'email', 'password', 'key', 'device'),
      () => VaultApi.verifyNewDevice('code'),
      VaultApi.checkNewDeviceApproved,
      VaultApi.syncNow,
      () => VaultApi.reconnect('password', 'key'),
      VaultApi.disconnect,
      () => VaultApi.deleteRemoteAccount('password', 'key'),
      VaultApi.listDevices,
      () => VaultApi.approveDevice('device'),
      () => VaultApi.revokeDevice('device'),
      VaultApi.auditEvents,
      () => VaultApi.recoverFromServer('url', 'email', 'code', 'key', 'password', 'device'),
      () => VaultApi.checkBreaches(['item']),
      () => VaultApi.listFeedback(null),
      () => VaultApi.getFeedback('test-id'),
      () => VaultApi.submitFeedback(const FeedbackSubmission(id: 'test-id', category: FeedbackCategory.bug, content: '测试')),
    ];
    for (final consent in [null, 'old-version']) {
      if (consent != null) bridge.settings['privacy_consent'] = consent;
      for (final request in requests) {
        await expectLater(request(), throwsA(isA<CoreException>().having((e) => e.code, 'code', 'privacy_required')));
      }
    }
    expect(bridge.networkCalls, 0);
    bridge.settings['privacy_consent'] = VaultApi.privacyVersion;
    await VaultApi.pingServer('https://test.invalid');
    expect(bridge.networkCalls, 1);
  });

  test('锁定先清状态；旧条目查询即使晚于锁定返回也不回填', () async {
    final state = AppState()..phase = AppPhase.unlocked;
    addTearDown(state.dispose);
    bridge.pendingItems = Completer<String>();
    bridge.pendingLock = Completer<void>();
    final refresh = state.refresh(sync: false);
    final locking = state.lock();
    expect(state.phase, AppPhase.locked);
    bridge.pendingItems!.complete('[{"id":"secret-item","vaultId":"vault","revision":1,"data":{"type":"note","title":"旧会话秘密","notes":"不得回填"}}]');
    await refresh;
    expect(state.items, isEmpty);
    expect(state.account, isNull);
    expect(state.phase, AppPhase.locked);
    bridge.pendingLock!.complete();
    await locking;
  });

  test('锁定后导出异步返回不能释放明文，锁定状态也不能新发导出', () async {
    final state = AppState()..phase = AppPhase.unlocked;
    addTearDown(state.dispose);
    bridge.pendingCsv = Completer<String>();
    final exporting = state.exportCsv();
    final rejected = expectLater(exporting, throwsA(isA<CoreException>().having((e) => e.code, 'code', 'session_expired')));
    await state.lock();
    // 即便另一次解锁已经完成，前一代会话结果仍必须失效。
    state.phase = AppPhase.unlocked;
    bridge.pendingCsv!.complete('title,password\n银行,秘密口令');
    await rejected;
    state.phase = AppPhase.locked;
    await expectLater(state.exportCsv(), throwsA(isA<CoreException>()));
  });

  testWidgets('已有保险库也必须先看到隐私同意；锁定销毁已打开的敏感路由和弹窗', (tester) async {
    await tester.pumpWidget(const VaultOneApp(dbPath: 'unused', logDir: 'unused'));
    await tester.pumpAndSettle();
    final state = AppScope.read(tester.element(find.byType(Navigator).first));
    expect(state.phase, AppPhase.locked);
    expect(find.textContaining('隐私'), findsWidgets);
    await state.acceptPrivacy();
    await tester.pumpAndSettle();
    await state.unlock('password', secretKey: 'key');
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: ItemEditor(
      target: const EditTarget.create(ItemKind.note),
      initial: const ItemData(kind: ItemKind.note, title: '会话中的敏感页面', notes: '未保存的秘密笔记'),
      onCancel: () {}, onSaved: (_) {},
    )))));
    await tester.pumpAndSettle();
    final pageContext = tester.element(find.byType(ItemEditor));
    unawaited(showDialog<void>(context: pageContext, builder: (_) => const AlertDialog(content: Text('秘密恢复码'))));
    await tester.pumpAndSettle();
    expect(find.text('秘密恢复码'), findsOneWidget);
    bridge.pendingLock = Completer<void>();
    final locking = state.lock();
    await tester.pump();
    expect(find.text('秘密恢复码', skipOffstage: false), findsNothing);
    expect(find.text('会话中的敏感页面', skipOffstage: false), findsNothing);
    expect(find.byType(ItemEditor), findsNothing);
    expect(navigator.mounted, isFalse);
    bridge.pendingLock!.complete();
    await locking;
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('CSV 保存位置晚于锁定返回：页面尚未销毁也不得写入明文文件', (tester) async {
    final temp = Directory.systemTemp.createTempSync('vaultone-export-lock-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final target = File('${temp.path}/locked.csv');
    final dialog = _SaveDialog();
    final state = await _openCsvExport(tester, bridge, dialog);
    final page = tester.element(find.byType(SettingsPage));
    await state.lock();
    // 不 pump：专门覆盖通知已发出、下一帧还没销毁旧页面的窗口。
    dialog.result.complete(FileSaveLocation(target.path));
    await tester.idle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.idle();
    expect(page.mounted, isTrue);
    expect(target.existsSync(), isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存有损 CSV'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CSV 取消保存位置不写文件、不显示导出成功', (tester) async {
    final dialog = _SaveDialog();
    await _openCsvExport(tester, bridge, dialog);
    dialog.result.complete(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存有损 CSV'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CSV 正常保存写入真实文件，完成后才显示成功', (tester) async {
    final temp = Directory.systemTemp.createTempSync('vaultone-export-success-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final target = File('${temp.path}/export.csv');
    final dialog = _SaveDialog();
    await _openCsvExport(tester, bridge, dialog);
    expect(find.textContaining('已保存有损 CSV'), findsNothing);
    expect(target.existsSync(), isFalse);
    dialog.result.complete(FileSaveLocation(target.path));
    await tester.idle();
    await _waitForIoMessage(tester, '已保存有损 CSV');
    expect(target.readAsStringSync(), 'title,password\n账户,测试秘密');
    expect(find.textContaining('已保存有损 CSV'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CSV 写入失败显示错误而不是成功，不留下导出文件', (tester) async {
    final temp = Directory.systemTemp.createTempSync('vaultone-export-failure-');
    addTearDown(() => temp.deleteSync(recursive: true));
    // 父路径是文件，跨平台稳定触发 FileSystemException，不依赖权限或磁盘状态。
    final blocker = File('${temp.path}/not-a-directory')..writeAsStringSync('unchanged');
    final target = File('${blocker.path}/export.csv');
    final dialog = _SaveDialog();
    await _openCsvExport(tester, bridge, dialog);
    dialog.result.complete(FileSaveLocation(target.path));
    await tester.idle();
    await _waitForIoMessage(tester, 'CSV 保存失败');
    expect(find.textContaining('已保存有损 CSV'), findsNothing);
    expect(find.textContaining('CSV 保存失败'), findsOneWidget);
    expect(target.existsSync(), isFalse);
    expect(blocker.readAsStringSync(), 'unchanged');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

}
