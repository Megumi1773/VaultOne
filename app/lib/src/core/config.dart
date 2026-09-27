/// 构建期配置。通过 `--dart-define` 覆盖，例如：
///
/// ```
/// flutter build windows --dart-define=VAULTONE_SERVER=https://sync.example.com
/// ```
abstract final class AppConfig {
  /// 默认同步服务地址（用户可在设置与登录页修改为自建服务器）。
  static const defaultServerUrl = String.fromEnvironment('VAULTONE_SERVER', defaultValue: 'https://sync.vaultone.app');

  static const privacyPolicyUrl = String.fromEnvironment('VAULTONE_PRIVACY_URL', defaultValue: 'https://vaultone.app/privacy');

  static const termsUrl = String.fromEnvironment('VAULTONE_TERMS_URL', defaultValue: 'https://vaultone.app/terms');

  static const supportEmail = 'support@vaultone.app';

  static const sourceUrl = 'https://github.com/vaultone/vaultone';

  /// 浏览器扩展安装页（上架 Chrome 应用店 / Edge 加载项后替换为商店地址）
  static const extensionUrl = String.fromEnvironment('VAULTONE_EXTENSION_URL', defaultValue: 'https://vaultone.app/browser');
}
