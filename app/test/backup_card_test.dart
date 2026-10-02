import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/l10n/strings.dart';
import 'package:vaultone/src/state/backup_card.dart';

void main() {
  final withDate = BackupCardData(
    email: 'yg@example.com',
    secretKey: 'V1-2H7K9M-3PQ4RS-5TVW6X-7YZ012-3H7K9M-3PQ4RS-5TVW6X',
    recoveryCode: 'R1-2H7K-9M3P-Q4RS-5TVW-6X7Y-Z012-3H7K-9M3P-Q4RS-5TVW-6X7Y-Z012',
    generatedAt: DateTime.utc(2026, 10, 2),
  );

  // `Picture.toImage` 需要真实光栅化，测试的 FakeAsync 时钟下会挂起，必须走 runAsync。
  testWidgets('备份卡按 700×900 逻辑尺寸渲染，倍率只影响输出像素', (tester) async {
    await tester.runAsync(() async {
      final single = await BackupCard.render(withDate, scale: 1);
      single.dispose();
      expect(single.width, 700);
      expect(single.height, 900);

      final doubled = await BackupCard.render(withDate);
      doubled.dispose();
      expect(doubled.width, 1400, reason: '700 × 2x');
      expect(doubled.height, 1800, reason: '900 × 2x');
    });
  });

  testWidgets('备份卡导出为真实 PNG 字节', (tester) async {
    await tester.runAsync(() async {
      final bytes = await BackupCard.pngBytes(withDate);
      expect(bytes.length, greaterThan(1024), reason: '不是空图');
      expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: 'PNG 签名');
    });
  });

  testWidgets('备份卡尺寸常量固定，文件名按语言给出', (tester) async {
    expect(BackupCard.logicalSize, const Size(700, 900));
    expect(BackupCard.defaultScale, 2);
    for (final language in AppStrings.supported) {
      expect(BackupCard.fileName(language), endsWith('.png'), reason: '$language');
    }
    expect(
      BackupCard.fileName(AppLanguage.en),
      isNot(BackupCard.fileName(AppLanguage.zhHans)),
      reason: '英文文件名不应残留中文',
    );
    expect(BackupCard.fileName(AppLanguage.zhHant), contains('備份卡'), reason: '繁中卡名应使用繁体字形');
  });

  testWidgets('备份卡按语言渲染：英文卡不含中文文案，繁中卡字形可用', (tester) async {
    await tester.runAsync(() async {
      for (final language in AppStrings.supported) {
        final bytes = await BackupCard.pngBytes(withDate, language: language);
        expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: '$language');
      }
    });
  });
}
