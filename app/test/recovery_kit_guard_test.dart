import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/state/recovery_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const enrollment = Enrollment(
    accountId: 'test-account',
    email: 'test@example.invalid',
    secretKey: 'test-secret-key',
    recoveryCode: 'test-recovery-code',
  );

  test('恢复套件会话失效后不生成或打开保存面板', () async {
    expect(await RecoveryKit.save(enrollment, canContinue: () => false), isNull);
  });

  test('恢复套件生成期间会话失效，不继续调用文件或分享插件', () async {
    var checks = 0;
    final path = await RecoveryKit.save(enrollment, canContinue: () => ++checks == 1);
    expect(checks, 2);
    expect(path, isNull);
  });
}
