import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// 让子树访问 [AppState]，并在其变化时重建依赖者。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// 只读取、不订阅（用于回调中）
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
