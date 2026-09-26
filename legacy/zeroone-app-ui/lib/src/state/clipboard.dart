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

/// 剪贴板服务（F-10）：敏感内容不进入系统剪贴板历史，到期自动清除。
class ClipboardService {
  ClipboardService._();

  static final notice = ValueNotifier<ClipboardNotice?>(null);

  static Timer? _timer;
  static int? _sequence;
  static String? _fallbackText;

  static Future<void> copy(String text, {required String label, bool sensitive = true, int clearAfterSeconds = 30}) async {
    _timer?.cancel();
    int? seq;
    if (sensitive) {
      try {
        seq = VaultApi.clipboardCopy(text);
      } catch (_) {
        seq = null;
      }
    }
    if (seq == null) {
      await Clipboard.setData(ClipboardData(text: text));
      _fallbackText = sensitive ? text : null;
    } else {
      _fallbackText = null;
    }
    _sequence = seq;

    notice.value = ClipboardNotice(label: label, sensitive: sensitive, seconds: clearAfterSeconds, startedAt: DateTime.now());
    if (sensitive && clearAfterSeconds > 0) {
      _timer = Timer(Duration(seconds: clearAfterSeconds), clearNow);
    } else {
      _timer = Timer(const Duration(seconds: 2), () => notice.value = null);
    }
  }

  static Future<void> clearNow() async {
    _timer?.cancel();
    final seq = _sequence;
    if (seq != null) {
      try {
        VaultApi.clipboardClear(seq);
      } catch (_) {}
    } else if (_fallbackText != null) {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == _fallbackText) await Clipboard.setData(const ClipboardData(text: ''));
    }
    _sequence = null;
    _fallbackText = null;
    notice.value = null;
  }
}
