import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Rust 内核返回的业务错误。
class CoreException implements Exception {
  CoreException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

typedef _CallNative = Pointer<Uint8> Function(Pointer<Uint8>, IntPtr, Pointer<IntPtr>);
typedef _CallDart = Pointer<Uint8> Function(Pointer<Uint8>, int, Pointer<IntPtr>);
typedef _FreeNative = Void Function(Pointer<Uint8>, IntPtr);
typedef _FreeDart = void Function(Pointer<Uint8>, int);

class _Bindings {
  _Bindings(DynamicLibrary lib)
      : call = lib.lookupFunction<_CallNative, _CallDart>('zo_call'),
        free = lib.lookupFunction<_FreeNative, _FreeDart>('zo_free');

  final _CallDart call;
  final _FreeDart free;
}

String _defaultLibraryPath() {
  if (Platform.isWindows) return 'zeroone_ffi.dll';
  if (Platform.isAndroid || Platform.isLinux) return 'libzeroone_ffi.so';
  if (Platform.isMacOS) return 'libzeroone_ffi.dylib';
  throw UnsupportedError('当前平台尚未接入内核');
}

DynamicLibrary _open(String path) => Platform.isIOS ? DynamicLibrary.process() : DynamicLibrary.open(path);

Uint8List _invoke(_Bindings b, Uint8List request) {
  final input = malloc<Uint8>(request.isEmpty ? 1 : request.length);
  final outLen = malloc<IntPtr>();
  final view = input.asTypedList(request.length);
  try {
    view.setAll(0, request);
    final out = b.call(input, request.length, outLen);
    final len = outLen.value;
    final bytes = Uint8List.fromList(out.asTypedList(len));
    // zo_free 会先清零再释放
    b.free(out, len);
    return bytes;
  } finally {
    view.fillRange(0, view.length, 0);
    malloc.free(input);
    malloc.free(outLen);
  }
}

Object? _decode(Uint8List bytes) {
  final res = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  if (res['ok'] == true) return res['result'];
  final err = (res['error'] as Map?)?.cast<String, dynamic>() ?? const {};
  throw CoreException(err['code'] as String? ?? 'internal', err['message'] as String? ?? '未知错误');
}

Uint8List _encode(String method, Map<String, Object?>? params) =>
    utf8.encode(jsonEncode({'method': method, 'params': params ?? const {}}));

/// 内核调用入口。
///
/// - [call]：在后台 isolate 执行，用于 Argon2id 派生、批量解密等耗时操作，避免阻塞 UI。
///   动态库在进程内只加载一次，内核状态（已解锁的会话）在所有 isolate 间共享。
/// - [callSync]：主 isolate 同步执行，只用于 TOTP、生成器、剪贴板等微秒级调用。
class Core {
  Core._();

  static String _path = '';
  static _Bindings? _bindings;

  static void load({String? path}) {
    _path = path ?? _defaultLibraryPath();
    _bindings = _Bindings(_open(_path));
  }

  static Object? callSync(String method, [Map<String, Object?>? params]) {
    final b = _bindings ?? (throw StateError('Core.load() 未调用'));
    final req = _encode(method, params);
    try {
      return _decode(_invoke(b, req));
    } finally {
      req.fillRange(0, req.length, 0);
    }
  }

  static Future<Object?> call(String method, [Map<String, Object?>? params]) async {
    final path = _path;
    final req = _encode(method, params);
    try {
      final response = await Isolate.run(() => _invoke(_Bindings(_open(path)), req));
      return _decode(response);
    } finally {
      req.fillRange(0, req.length, 0);
    }
  }
}
