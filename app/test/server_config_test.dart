import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/config.dart';
import 'package:vaultone/src/core/ffi.dart';

void main() {
  test('真机 HTTP 必须显式启用且仅 Debug 私网端点可用', () {
    const url = 'http://192.168.0.4:9777';
    expect(
      () =>
          AppConfig.validateServerUrl(url, production: false, lanDebug: false),
      throwsA(isA<CoreException>()),
    );
    expect(
      AppConfig.validateServerUrl(
        url,
        production: false,
        lanDebug: true,
        debugBuild: true,
      ),
      url,
    );
    expect(
      () => AppConfig.validateServerUrl(
        url,
        production: true,
        lanDebug: true,
        debugBuild: true,
      ),
      throwsA(isA<CoreException>()),
    );
    expect(
      () => AppConfig.validateServerUrl(
        url,
        production: false,
        lanDebug: true,
        debugBuild: false,
      ),
      throwsA(isA<CoreException>()),
    );
    for (final value in [
      'http://8.8.8.8:9777',
      'http://198.18.0.1:9777',
      'http://100.64.0.1:9777',
      'http://dev.example.test:9777',
      'http://192.168.0.4:9777/path',
      'http://192.168.0.4:0',
    ]) {
      expect(
        () => AppConfig.validateServerUrl(
          value,
          production: false,
          lanDebug: true,
        ),
        throwsA(isA<CoreException>()),
      );
    }
    for (final host in [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.0.4',
    ]) {
      expect(AppConfig.isPrivateIpv4(host), isTrue);
    }
    expect(AppConfig.isPrivateIpv4('192.168.0.999'), isFalse);
    expect(AppConfig.isPrivateIpv4('010.0.0.1'), isFalse);
  });

  test('开发默认 Java 回环地址，发布不接受隐式本机后端', () {
    expect(AppConfig.defaultServerUrl, 'http://127.0.0.1:9777');
    expect(
      AppConfig.validateServerUrl(
        AppConfig.defaultServerUrl,
        production: false,
      ),
      AppConfig.defaultServerUrl,
    );
    expect(
      () => AppConfig.validateServerUrl(
        AppConfig.defaultServerUrl,
        production: true,
      ),
      throwsA(isA<CoreException>()),
    );
    expect(
      AppConfig.validateServerUrl(
        'https://cloud.example.test/',
        production: true,
      ),
      'https://cloud.example.test',
    );
  });

  test('不接受凭据、查询参数、片段或非回环 HTTP；不自动降级', () {
    for (final value in [
      'http://cloud.example.test',
      'https://u:p@cloud.example.test',
      'https://cloud.example.test?token=x',
      'https://cloud.example.test/#fragment',
      'file:///tmp/test',
    ]) {
      expect(
        () => AppConfig.validateServerUrl(value, production: false),
        throwsA(isA<CoreException>()),
      );
    }
    expect(
      AppConfig.validateServerUrl('https://127.0.0.1:9777', production: false),
      'https://127.0.0.1:9777',
    );
  });
}
