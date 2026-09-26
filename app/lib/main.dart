import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/core/api.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // 数据目录：Windows %APPDATA%\com.vaultone\VaultOne、macOS ~/Library/Application Support、移动端应用沙盒
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final logDir = '${support.path}${sep}logs';
  await Directory(logDir).create(recursive: true);

  // 全局错误处理：只记录异常类型，不记录可能包含用户数据的消息体
  FlutterError.onError = (details) {
    VaultApi.log('flutter error: ${details.exception.runtimeType} in ${details.library ?? '-'}', level: 'error');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    VaultApi.log('uncaught: ${error.runtimeType}', level: 'error');
    return true;
  };

  runApp(VaultOneApp(dbPath: '${support.path}${sep}vault.db', logDir: logDir));
}
