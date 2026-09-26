// 纯 Dart 单元测试：条目模型与 Rust serde 结构（camelCase / type / match）的 JSON 往返一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';

void main() {
  test('ItemData JSON 往返与 Rust ItemData 字段名一致', () {
    const data = ItemData(
      kind: ItemKind.login,
      title: '某银行企业网银',
      urls: [ItemUrl(url: 'https://ebank.example.com', match: UrlMatch.host)],
      username: 'user@example.com',
      password: 'p@ss',
      totp: TotpConfig(secret: 'JBSWY3DPEHPK3PXP'),
      customFields: [CustomField(label: '账户别名', value: '备用')],
    );
    final json = data.toJson();
    expect(json['type'], 'login');
    expect((json['urls'] as List).first, {'url': 'https://ebank.example.com', 'match': 'host'});
    expect(json.containsKey('customFields'), isTrue);
    final back = ItemData.fromJson(json.cast<String, dynamic>());
    expect(back.title, data.title);
    expect(back.urls.single.match, UrlMatch.host);
    expect(back.totp?.secret, 'JBSWY3DPEHPK3PXP');
  });

  test('未知枚举值安全降级', () {
    expect(ItemKind.parse('unknown'), ItemKind.login);
    expect(UrlMatch.parse(null), UrlMatch.domain);
  });

  test('支付卡品牌与尾号', () {
    const card = CardData(cardholder: 'A', number: '4111 1111 1111 1234', expiry: '12/30', cvv: '123', pin: '');
    expect(card.last4, '1234');
  });

  test('搜索文本包含标题、用户名与 URL，且不包含密码', () {
    const d = ItemData(kind: ItemKind.login, title: 'GitHub', username: 'alice', password: 'secret-pw', urls: [ItemUrl(url: 'github.com')]);
    expect(d.searchText, contains('github'));
    expect(d.searchText, contains('alice'));
    expect(d.searchText, isNot(contains('secret-pw')));
  });
}
