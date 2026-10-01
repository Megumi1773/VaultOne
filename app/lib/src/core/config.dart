import 'package:flutter/foundation.dart';

import 'ffi.dart';

/// 构建期配置。通过 `--dart-define` 覆盖，例如：
///
/// ```
/// flutter build windows --dart-define=VAULTONE_SERVER=https://sync.example.com
/// ```
abstract final class AppConfig {
  /// 本机 Java 开发服务。发布构建必须显式指定 HTTPS 地址，不能把回环地址当作生产服务。
  static const javaDevelopmentUrl = 'http://127.0.0.1:9777';
  static const defaultServerUrl = String.fromEnvironment(
    'VAULTONE_SERVER',
    defaultValue: javaDevelopmentUrl,
  );

  static const allowLanHttp = bool.fromEnvironment(
    'VAULTONE_ALLOW_LAN_HTTP',
    defaultValue: false,
  );

  static bool isPrivateIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4 ||
        parts.any((p) => !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(p))) {
      return false;
    }
    final values = parts.map(int.parse).toList();
    if (values.any((v) => v > 255)) return false;
    return values[0] == 10 ||
        (values[0] == 172 && values[1] >= 16 && values[1] <= 31) ||
        (values[0] == 192 && values[1] == 168);
  }

  static String? developmentHttpServer(String selected) {
    final uri = Uri.parse(selected);
    return kDebugMode &&
            allowLanHttp &&
            uri.scheme == 'http' &&
            isPrivateIpv4(uri.host)
        ? selected
        : null;
  }

  static String serverUrl(String requested, {bool production = kReleaseMode}) {
    final selected = (allowCustomServer ? requested : defaultServerUrl).trim();
    return validateServerUrl(selected, production: production);
  }

  static String validateServerUrl(
    String value, {
    bool production = kReleaseMode,
    bool lanDebug = allowLanHttp,
    bool debugBuild = kDebugMode,
  }) {
    final uri = Uri.tryParse(value.trim());
    const loopback = {'127.0.0.1', 'localhost', '::1', '10.0.2.2'};
    if (uri == null ||
        uri.host.isEmpty ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' ||
            (!production &&
                uri.scheme == 'http' &&
                (loopback.contains(uri.host) ||
                    (debugBuild &&
                        lanDebug &&
                        isPrivateIpv4(uri.host) &&
                        (uri.path.isEmpty || uri.path == '/'))))) ||
        (production && loopback.contains(uri.host))) {
      throw CoreException(
        'server_configuration',
        production
            ? '发布构建需要显式配置有效的 HTTPS Java 服务地址'
            : '服务器地址无效；真机 HTTP 调试需开启 VAULTONE_ALLOW_LAN_HTTP 并指定私网 IP',
      );
    }
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  /// 是否允许用户自定义同步服务器（自部署模式）。默认关闭：客户端固定连接官方服务端。
  /// 计划在付费 / 高级企划中通过 `--dart-define=VAULTONE_ALLOW_CUSTOM_SERVER=true` 开放。
  static const allowCustomServer = bool.fromEnvironment(
    'VAULTONE_ALLOW_CUSTOM_SERVER',
    defaultValue: false,
  );

  static const privacyPolicyUrl = String.fromEnvironment(
    'VAULTONE_PRIVACY_URL',
    defaultValue: 'https://vaultone.app/privacy',
  );

  static const termsUrl = String.fromEnvironment(
    'VAULTONE_TERMS_URL',
    defaultValue: 'https://vaultone.app/terms',
  );

  static const supportEmail = 'support@vaultone.app';

  static const sourceUrl = 'https://github.com/vaultone/vaultone';

  /// 浏览器扩展安装页（上架 Chrome 应用店 / Edge 加载项后替换为商店地址）
  static const extensionUrl = String.fromEnvironment(
    'VAULTONE_EXTENSION_URL',
    defaultValue: 'https://vaultone.app/browser',
  );
}
