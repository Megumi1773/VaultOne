import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// TOTP 二维码扫描（F-07，仅移动端）。直接使用 `mobile_scanner`（CameraX / AVFoundation + 本地条码识别），
/// 图像只在本机处理；识别到 `otpauth://` 链接后立即返回。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && raw.toLowerCase().startsWith('otpauth://')) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('扫描两步验证二维码'), backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Stack(
          children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(border: Border.all(color: Colors.white70, width: 2), borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: Text('将网站提供的二维码置于框内', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      );
}
