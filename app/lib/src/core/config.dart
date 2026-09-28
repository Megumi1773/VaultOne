/// 构建期配置。通过 `--dart-define` 覆盖，例如：
///
/// ```
/// flutter build windows --dart-define=VAULTONE_SERVER=https://sync.example.com
/// ```
abstract final class AppConfig {
  /// 官方同步服务地址。默认即为官方服务端；`--dart-define` 仅用于内部测试与将来的
  /// 自部署模式，普通用户不可更改。
  static const defaultServerUrl = String.fromEnvironment('VAULTONE_SERVER', defaultValue: 'https://sync.vaultone.app');

  /// 是否允许用户自定义同步服务器（自部署模式）。默认关闭：客户端固定连接官方服务端。
  /// 计划在付费 / 高级企划中通过 `--dart-define=VAULTONE_ALLOW_CUSTOM_SERVER=true` 开放。
  static const allowCustomServer = bool.fromEnvironment('VAULTONE_ALLOW_CUSTOM_SERVER', defaultValue: false);

  static const privacyPolicyUrl = String.fromEnvironment('VAULTONE_PRIVACY_URL', defaultValue: 'https://vaultone.app/privacy');

  static const termsUrl = String.fromEnvironment('VAULTONE_TERMS_URL', defaultValue: 'https://vaultone.app/terms');

  static const supportEmail = 'support@vaultone.app';

  static const sourceUrl = 'https://github.com/vaultone/vaultone';

  /// 浏览器扩展安装页（上架 Chrome 应用店 / Edge 加载项后替换为商店地址）
  static const extensionUrl = String.fromEnvironment('VAULTONE_EXTENSION_URL', defaultValue: 'https://vaultone.app/browser');
}
