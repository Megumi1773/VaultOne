import '../rust/api.dart' show BridgeError;

/// 内核返回的业务错误。`code` 为稳定错误码（见 vault-core `VaultError::code`），`message` 可直接展示。
class CoreException implements Exception {
  CoreException(this.code, this.message);

  factory CoreException.from(BridgeError e) => CoreException(e.code, e.message);

  final String code;
  final String message;

  bool get isNetwork => code == 'network';
  bool get isUnauthorized => code == 'unauthorized';

  @override
  String toString() => message;
}

/// 把 Rust 侧抛出的 [BridgeError] 统一转换为 [CoreException]。
Future<T> guard<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on BridgeError catch (e) {
    throw CoreException.from(e);
  }
}

T guardSync<T>(T Function() f) {
  try {
    return f();
  } on BridgeError catch (e) {
    throw CoreException.from(e);
  }
}
