import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../core/models.dart';

/// 生成可打印的 Recovery Kit（HTML），并让用户选择保存位置。
///
/// 文件只写到用户选择的位置，不经过任何网络或应用缓存。
abstract final class RecoveryKit {
  static String html(Enrollment e) {
    const esc = HtmlEscape();
    final date = DateTime.now().toIso8601String().substring(0, 10);
    return '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>ZeroOne Recovery Kit</title>
<style>
  @page { size: A4; margin: 18mm; }
  body { font-family: "Segoe UI","Microsoft YaHei",sans-serif; color:#0a0a0a; max-width: 720px; margin: 40px auto; padding: 0 24px; }
  .brand { display:flex; align-items:center; gap:12px; font-weight:800; letter-spacing:.14em; font-size:22px; }
  .mark { width:30px; height:30px; background:#FFD60A; clip-path: polygon(24% 0,100% 0,100% 76%,76% 100%,0 100%,0 24%); }
  .brand b { color:#c9a400; }
  h1 { font-size: 28px; margin: 36px 0 6px; letter-spacing:-.02em; }
  p.lead { color:#555; margin:0 0 28px; line-height:1.6; }
  .box { border:1.5px solid #0a0a0a; padding:18px 20px; margin:14px 0; clip-path: polygon(10px 0,100% 0,100% calc(100% - 10px),calc(100% - 10px) 100%,0 100%,0 10px); }
  .label { font-size:11px; font-weight:700; letter-spacing:.16em; color:#666; text-transform:uppercase; }
  .value { font-family:"Cascadia Mono",Consolas,monospace; font-size:19px; font-weight:600; margin-top:8px; word-break:break-all; letter-spacing:.04em; }
  .blank { border-bottom:1px solid #999; height:30px; margin-top:6px; }
  ul { color:#333; line-height:1.9; padding-left:20px; }
  .foot { margin-top:36px; font-size:12px; color:#888; border-top:1px solid #ddd; padding-top:14px; }
</style></head><body>
<div class="brand"><div class="mark"></div>ZER<b>0</b>NE</div>
<h1>Recovery Kit · 恢复套件</h1>
<p class="lead">这是找回你保险库的唯一凭据。ZeroOne 采用零知识架构，我们无法重置你的主密码，也无法替你恢复数据。<br>请打印或离线保存本页，不要存放在网盘、邮箱或聊天记录中。</p>
<div class="box"><div class="label">账户邮箱</div><div class="value">${esc.convert(e.email)}</div></div>
<div class="box"><div class="label">Secret Key · 设备密钥</div><div class="value">${esc.convert(e.secretKey)}</div></div>
<div class="box"><div class="label">Recovery Code · 恢复码</div><div class="value">${esc.convert(e.recoveryCode)}</div></div>
<div class="box"><div class="label">主密码（可选，手写）</div><div class="blank"></div></div>
<ul>
  <li>在新设备登录时，需要同时输入 <b>主密码</b> 与 <b>Secret Key</b>。</li>
  <li>忘记主密码时，可用 <b>Secret Key + 恢复码</b> 重设主密码；重设后此恢复码立即作废，请保存新的 Recovery Kit。</li>
  <li>账户 ID：${esc.convert(e.accountId)}</li>
</ul>
<div class="foot">生成于 $date · 能打开你保险库的，只有一个人——你自己。</div>
</body></html>''';
  }

  /// 返回保存路径；用户取消时返回 null。
  static Future<String?> save(Enrollment e) async {
    final loc = await getSaveLocation(
      suggestedName: 'ZeroOne-Recovery-Kit.html',
      acceptedTypeGroups: const [XTypeGroup(label: 'HTML', extensions: ['html'])],
    );
    if (loc == null) return null;
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.html')) path = '$path.html';
    await File(path).writeAsString(html(e), flush: true);
    return path;
  }
}
