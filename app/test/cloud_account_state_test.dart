import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/config.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/rust/api/vault.dart' as rv;
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';

const _kit = rv.EnrollmentDto(
  accountId: 'account',
  email: 'user@example.test',
  secretKey: 'SECRET-TEST',
  recoveryCode: 'RECOVERY-TEST',
);

class _CloudBridge implements RustLibApi {
  bool connected = false;
  bool kitPending = false;
  bool operationPending = false;
  bool failComplete = true;
  String boundServer = AppConfig.defaultServerUrl;
  int prepared = 0;
  int completed = 0;
  int localCreates = 0;
  int localRecoveries = 0;
  int syncs = 0;
  int feedbackCalls = 0;
  final passwords = <String>[];

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async =>
      key == 'privacy_consent' ? VaultApi.privacyVersion : null;
  @override
  Future<rv.EnrollmentDto> crateApiCloudAccountPrepareRegistration({
    required String serverUrl,
    required String email,
    required String password,
    required String deviceName,
  }) async {
    expect(serverUrl, AppConfig.defaultServerUrl);
    prepared++;
    operationPending = true;
    return _kit;
  }

  @override
  Future<rv.EnrollmentDto?> crateApiCloudAccountCompleteRegistration({
    required String serverUrl,
    required String password,
    required String secretKey,
    required String deviceName,
  }) async {
    completed++;
    passwords.add(password);
    expect(secretKey, _kit.secretKey);
    if (failComplete) throw CoreException('network', '连接失败');
    connected = true;
    operationPending = false;
    kitPending = prepared > 0;
    return kitPending ? _kit : null;
  }

  @override
  Future<rv.EnrollmentDto?> crateApiCloudAccountPendingEnrollment() async =>
      kitPending ? _kit : null;
  @override
  Future<String?> crateApiCloudAccountPendingOperation() async =>
      operationPending ? 'register' : null;
  @override
  Future<void> crateApiCloudAccountConfirmEnrollment() async {
    kitPending = false;
  }

  @override
  Future<RemoteStatusDto?> crateApiSyncRemoteStatus() async => connected
      ? RemoteStatusDto(
          serverUrl: boundServer,
          deviceId: 'device',
          deviceName: 'test',
          pending: BigInt.one,
        )
      : null;
  @override
  Future<rv.AccountInfo> crateApiVaultAccountInfo() async => rv.AccountInfo(
    accountId: 'account',
    email: _kit.email,
    kdfSummary: 'test',
    pendingChanges: BigInt.one,
    itemCount: BigInt.one,
  );
  @override
  Future<String> crateApiVaultListItems() async => '[]';
  @override
  Future<String> crateApiVaultListTrash() async => '[]';
  @override
  Future<String> crateApiVaultCategoryTree() async => '[]';
  @override
  Future<void> crateApiVaultUnlock({
    required String password,
    required String secretKey,
  }) async {}
  @override
  Future<void> crateApiVaultLock() async {}
  @override
  Future<void> crateApiLoggingLogEvent({
    required String level,
    required String message,
  }) async {}
  @override
  Future<SyncReportDto> crateApiSyncSyncNow() async {
    syncs++;
    return const SyncReportDto(
      pulled: 0,
      pushed: 0,
      merged: 0,
      conflicts: 0,
      credentialsUpdated: false,
    );
  }

  @override
  Future<rv.EnrollmentDto> crateApiVaultCreateAccount({
    required String email,
    required String password,
  }) async {
    localCreates++;
    throw StateError('不应调用纯本地建号');
  }

  @override
  Future<rv.EnrollmentDto> crateApiVaultRecoverLocal({
    required String recoveryCode,
    required String secretKey,
    required String newPassword,
  }) async {
    localRecoveries++;
    throw StateError('不应调用本地恢复');
  }

  @override
  Future<String> crateApiFeedbackListFeedback({
    int? before,
    required int limit,
  }) async {
    feedbackCalls++;
    return '{"items":[],"next_before":null}';
  }

  @override
  Future<void> crateApiSyncConfigureDevelopmentHttp({String? serverUrl}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CloudBridge bridge;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    bridge = _CloudBridge();
    RustLib.initMock(api: bridge);
  });
  tearDown(() => RustLib.dispose());

  test('注册失败停留待确认入口，重试不重建密钥；服务端确认及备份后才能进入', () async {
    final state = AppState()
      ..phase = AppPhase.onboarding
      ..privacyAccepted = true;
    addTearDown(state.dispose);
    await expectLater(
      state.createAccount(_kit.email, 'password'),
      throwsA(isA<CoreException>()),
    );
    expect(state.phase, AppPhase.cloudSetup);
    expect(state.pendingEnrollment, isNull);
    expect(state.hasStoredSecretKey, isTrue);
    expect(bridge.prepared, 1);
    expect(bridge.localCreates, 0);
    bridge.failComplete = false;
    await state.completeCloudRegistration('password');
    expect(state.phase, AppPhase.onboarding);
    expect(state.pendingEnrollment?.accountId, _kit.accountId);
    expect(bridge.prepared, 1);
    expect(bridge.completed, 2);
    expect(bridge.passwords, ['password', 'password']);
    await state.finishOnboarding();
    expect(state.phase, AppPhase.unlocked);
    expect(state.remote, isNotNull);
    await state.lock();
  });

  test('旧纯本地库进入接入入口，不清库、不重新创建身份', () async {
    final state = AppState()
      ..phase = AppPhase.locked
      ..accountId = 'account'
      ..privacyAccepted = true;
    addTearDown(state.dispose);
    await state.unlock('password', secretKey: _kit.secretKey);
    expect(state.phase, AppPhase.cloudSetup);
    expect(bridge.prepared, 0);
    bridge.failComplete = false;
    await state.completeCloudRegistration('password');
    expect(state.phase, AppPhase.unlocked);
    expect(bridge.localCreates, 0);
    await state.lock();
  });

  test('未完成云注册不能通过恢复套件确认进入条目界面', () async {
    final state = AppState()..phase = AppPhase.onboarding;
    addTearDown(state.dispose);
    await expectLater(state.finishOnboarding(), throwsA(isA<CoreException>()));
    expect(state.phase, AppPhase.onboarding);
  });

  test('旧服务器绑定不会静默换成 Java，自动同步和在线业务均要求重新验证', () async {
    bridge.connected = true;
    bridge.boundServer = 'https://old.example.test';
    final state = AppState()
      ..phase = AppPhase.locked
      ..accountId = 'account'
      ..privacyAccepted = true;
    addTearDown(state.dispose);
    await state.unlock('password', secretKey: _kit.secretKey);
    expect(state.phase, AppPhase.unlocked);
    expect(state.syncState, SyncState.needsReconnect);
    await state.syncNow();
    expect(bridge.syncs, 0);
    await expectLater(
      VaultApi.listFeedback(null),
      throwsA(
        isA<CoreException>().having((e) => e.code, 'code', 'server_mismatch'),
      ),
    );
    expect(bridge.feedbackCalls, 0);
    await state.lock();
  });
}
