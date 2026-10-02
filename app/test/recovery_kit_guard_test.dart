import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/l10n/strings.dart';
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

  test('恢复套件三种语言都能生成 PDF，文件名按语言给出', () async {
    for (final language in AppStrings.supported) {
      final bytes = await RecoveryKit.build(enrollment, language: language);
      expect(bytes.sublist(0, 5), '%PDF-'.codeUnits, reason: '$language 应是 PDF');
      expect(bytes.length, greaterThan(1024), reason: '$language 不是空文档');
    }
    // PDF 文件名刻意保持语言无关的 ASCII：它要落到文件系统与系统分享面板，
    // 跨平台最稳妥。备份卡文件名则随语言变化（见 backup_card_test）。
    for (final language in AppStrings.supported) {
      expect(
        RecoveryKit.fileName(language),
        matches(RegExp(r'^[\x20-\x7E]+\.pdf$')),
        reason: '$language 的 PDF 文件名应为纯 ASCII',
      );
    }
  });
}
