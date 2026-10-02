// 应用商店截图生成（真实 UI + 真实 Rust 内核 + 演示数据），输出 PNG 到 store/screenshots/。
//
//   cd app
//   flutter test integration_test/screenshots_test.dart -d windows --dart-define=SCREENSHOT_DIR=../store/screenshots
//
// 尺寸按各商店的必需规格生成（docs/07 §2）：
//   desktop        1280×800  @2x → 2560×1600（Mac App Store / Microsoft Store）
//   iphone-6.9     440×956   @3x → 1320×2868（App Store iPhone 必需尺寸）
//   ipad-13        1032×1376 @2x → 2064×2752（App Store iPad 必需尺寸；工程支持 iPad）
//   android-phone  360×640   @3x → 1080×1920（Google Play：长宽比不得超过 2:1）
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vaultone/src/app.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/clipboard.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/home.dart';

const _outDir = String.fromEnvironment('SCREENSHOT_DIR', defaultValue: '../store/screenshots');
const _password = 'Correct-Horse-Battery-Staple-42';

Future<void> settle(WidgetTester tester, [int ms = 900]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('等待超时：$finder');
}

Future<void> shot(WidgetTester tester, String folder, String name) async {
  await settle(tester);
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final bytes = await tester.runAsync(() async {
    // 根层带有 dpr 变换，坐标为物理像素
    final image = await layer.toImage(Offset.zero & (view.size * tester.view.devicePixelRatio), pixelRatio: 1);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  });
  final file = File('$_outDir/$folder/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!);
}

Future<void> seed() async {
  ItemData login(String title, String user, String pw, String url, {TotpConfig? totp, bool fav = false}) => ItemData(
        kind: ItemKind.login,
        title: title,
        username: user,
        password: pw,
        urls: [ItemUrl(url: url)],
        totp: totp,
        favorite: fav,
      );
  final items = [
    login('GitHub', 'alice@example.com', 'vK9#qLm2\$Zp8!wRt5@Yx', 'https://github.com', totp: const TotpConfig(secret: 'JBSWY3DPEHPK3PXP'), fav: true),
    login('招商银行', 'alice', 'Tr0ub4dour-Correct-Horse-9', 'https://www.cmbchina.com', fav: true),
    login('阿里云', 'alice@example.com', 'Q7!pZr#2mWx9*Lc4', 'https://aliyun.com', totp: const TotpConfig(secret: 'KRSXG5CTMVRXEZLU')),
    login('Gmail', 'alice.w@gmail.com', 'password123', 'https://mail.google.com'),
    login('Figma', 'alice@example.com', 'password123', 'https://figma.com'),
    login('企业 VPN', 'alice.wang', 'Blue-Orbit-Candle-Harbor-58', 'https://vpn.example.com'),
    const ItemData(
      kind: ItemKind.card,
      title: '招行信用卡',
      card: CardData(cardholder: 'ALICE WANG', number: '4111 1111 1111 1234', expiry: '08/29', cvv: '123'),
    ),
    const ItemData(kind: ItemKind.note, title: '服务器应急预案', notes: '主备切换步骤与联系人……'),
    const ItemData(
      kind: ItemKind.identity,
      title: '身份证',
      identity: IdentityData(fullName: '王爱丽', phone: '138****0000', idNumber: '110101199001011234'),
    ),
  ];
  for (final i in items) {
    await VaultApi.createItem(i);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(() async => RustLib.init());

  Future<void> run(WidgetTester tester, String folder, Size logical, double dpr) async {
    tester.view.physicalSize = logical * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final tmp = await Directory.systemTemp.createTemp('vaultone_shots_');

    await tester.pumpWidget(VaultOneApp(dbPath: '${tmp.path}/vault.db', logDir: '${tmp.path}/logs'));
    await waitFor(tester, find.text('同意并继续'));
    await shot(tester, folder, '01-privacy');
    await tester.tap(find.text('同意并继续'));
    await waitFor(tester, find.text('创建我的保险库'));
    await shot(tester, folder, '02-welcome');

    await tester.tap(find.text('创建我的保险库'));
    await waitFor(tester, find.text('设置主密码'));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'alice@example.com');
    await tester.enterText(fields.at(1), _password);
    await tester.enterText(fields.at(2), _password);
    await tester.pump();
    await tester.tap(find.text('创建保险库'));
    await waitFor(tester, find.text('保存你的 Recovery Kit'));
    await shot(tester, folder, '03-recovery-kit');
    await tester.tap(find.byTooltip('复制').first);
    // 复制会弹出 60s 的剪贴板提示，窄屏下会盖住下方按钮；先清掉再继续。
    await ClipboardService.clearNow();
    await tester.pump();
    // 窄屏（如 360×640）下确认框与按钮在首屏之下，需先滚动到可视区再点。
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.text('进入保险库'));
    await settle(tester, 300);
    await tester.tap(find.text('进入保险库'));
    await waitFor(tester, find.byType(HomeScreen));

    await ClipboardService.clearNow();
    await seed();
    final state = AppScope.read(tester.element(find.byType(HomeScreen)));
    await state.refresh(sync: false);
    await settle(tester);
    await shot(tester, folder, '04-vault');

    // 打开 GitHub 条目。宽度 ≥ 720 时主界面为分栏布局（与 HomeScreen 的断点一致）
    if (logical.width >= 720) {
      await tester.tap(find.text('GitHub').first);
      await shot(tester, folder, '05-item-totp');
      await tester.tap(find.text('密码生成器'));
      await shot(tester, folder, '06-generator');
      await tester.tap(find.text('安全中心'));
      await shot(tester, folder, '07-security');
      await tester.tap(find.text('设置'));
      await shot(tester, folder, '08-settings');
    } else {
      await tester.tap(find.text('GitHub').first);
      await waitFor(tester, find.byType(BackButton));
      await shot(tester, folder, '05-item-totp');
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      // 窄屏走底部导航（标签用短名），不再有抽屉。
      await tester.tap(find.text('生成器'));
      await settle(tester);
      await shot(tester, folder, '06-generator');
      await tester.tap(find.text('安全'));
      await settle(tester);
      await shot(tester, folder, '07-security');
    }

    await state.lock();
    await waitFor(tester, find.text('欢迎回来'));
    await shot(tester, folder, '09-unlock');
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, 300);
  }

  testWidgets('桌面截图', (tester) => run(tester, 'desktop', const Size(1280, 800), 2));
  testWidgets('iPhone 6.9″ 截图', (tester) => run(tester, 'iphone-6.9', const Size(440, 956), 3));
  testWidgets('iPad 13″ 截图', (tester) => run(tester, 'ipad-13', const Size(1032, 1376), 2));
  testWidgets('Android 手机截图', (tester) => run(tester, 'android-phone', const Size(360, 640), 3));
}
