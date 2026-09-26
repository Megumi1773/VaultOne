import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';

class ClipboardNotice {
  const ClipboardNotice({required this.label, required this.sensitive, required this.seconds, required this.startedAt});

  final String label;
  final bool sensitive;
  final int seconds;
  final DateTime startedAt;
}

/// 剪贴板服务（F-10）：
/// - 桌面端经 Rust `arboard` 写入，并标记"不进入剪贴板历史 / 不云同步 / 不被剪贴板监控"；
/// - 移动端使用系统剪贴板；
/// - 到期后只有剪贴板内容仍是我们写入的那一份时才清空，不误删用户之后复制的内容。
class ClipboardService {
  ClipboardService._();

  static final notice = ValueNotifier<ClipboardNotice?>(null);

  static Timer? _timer;
  static bool _native = false;
  static String? _fallbackText;

  static Future<void> copy(String text, {required String label, bool sensitive = true, int clearAfterSeconds = 30}) async {
    _timer?.cancel();
    _native = sensitive && _tryNative(text);
    if (!_native) {
      await Clipboard.setData(ClipboardData(text: text));
      _fallbackText = sensitive ? text : null;
    } else {
      _fallbackText = null;
    }

    notice.value = ClipboardNotice(label: label, sensitive: sensitive, seconds: clearAfterSeconds, startedAt: DateTime.now());
    if (sensitive && clearAfterSeconds > 0) {
      _timer = Timer(Duration(seconds: clearAfterSeconds), clearNow);
    } else {
      _timer = Timer(const Duration(seconds: 2), () => notice.value = null);
    }
  }

  static bool _tryNative(String text) {
    try {
      return VaultApi.clipboardCopySensitive(text);
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearNow() async {
    _timer?.cancel();
    if (_native) {
      try {
        VaultApi.clipboardClearIfUnchanged();
      } catch (_) {}
    } else if (_fallbackText != null) {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == _fallbackText) await Clipboard.setData(const ClipboardData(text: ''));
    }
    _native = false;
    _fallbackText = null;
    notice.value = null;
  }
}
