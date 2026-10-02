import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/conflict_models.dart';
import 'package:vaultone/src/core/models.dart';

/// 冲突字段的 wire 名是**跨语言契约**：内核用 `serde(rename_all = "camelCase")` 序列化，
/// Dart 侧用 `ConflictField.values.byName` 解析。任一侧多一个少一个，都会在运行期抛异常
/// （例如内核新增字段后旧客户端打开冲突页直接崩）。
///
/// 这份清单与 `crates/vault-core/src/conflict_tests.rs` 的
/// `conflict_field_wire_names_are_a_frozen_contract` 必须逐字一致；改动任一侧都要同步。
const _wireNames = [
  'type',
  'title',
  'urls',
  'username',
  'password',
  'totp',
  'notes',
  'card',
  'identity',
  'customFields',
  'favorite',
  'tags',
  'category',
  'deleted',
  'resolution',
];

void main() {
  test('Dart 冲突字段与内核 wire 名逐字一致', () {
    expect(ConflictField.values.map((f) => f.name).toList(), _wireNames);
  });

  test('每个 wire 名都能被 values.byName 解析，未知名字会抛错', () {
    for (final name in _wireNames) {
      expect(ConflictField.values.byName(name).name, name);
    }
    // 内核将来新增而本客户端未跟上的字段：必须是明确抛错，而不是静默变成某个默认值。
    expect(() => ConflictField.values.byName('futureField'), throwsArgumentError);
  });

  test('ConflictDetail 能解析含标签与分类冲突的载荷', () {
    final json = <String, Object?>{
      'id': 'c1',
      'itemId': 'i1',
      'state': 'pending',
      'stale': false,
      'fields': ['tags', 'category'],
      'local': {'revision': 2, 'deleted': false, 'data': {'type': 'login', 'title': 't', 'tags': ['工作'], 'category': '金融'}},
      'remote': {'revision': 3, 'deleted': false, 'data': {'type': 'login', 'title': 't', 'tags': ['个人'], 'category': '开发'}},
      'suggested': {'type': 'login', 'title': 't'},
    };
    final detail = ConflictDetail.fromJson(json);
    expect(detail.fields, [ConflictField.tags, ConflictField.category]);

    // 逐字段裁决：两侧取值都能从候选快照里取出来（`field.name` 即 JSON 键）。
    expect(detail.local.value(ConflictField.tags), ['工作']);
    expect(detail.remote.value(ConflictField.category), '开发');
  });

  test('标签与分类不是机密，隐藏敏感值时仍可见', () {
    expect(ConflictField.tags.sensitive, isFalse);
    expect(ConflictField.category.sensitive, isFalse);
    // 对照：真正的机密仍然默认隐藏。
    expect(ConflictField.password.sensitive, isTrue);
    expect(ConflictField.totp.sensitive, isTrue);
  });

  test('逐字段裁决可以只选标签一方', () {
    final detail = ConflictDetail.fromJson(<String, Object?>{
      'id': 'c1',
      'itemId': 'i1',
      'state': 'pending',
      'stale': false,
      'fields': ['tags'],
      'local': {'revision': 2, 'deleted': false, 'data': {'type': 'login', 'title': 't', 'tags': ['工作']}},
      'remote': {'revision': 3, 'deleted': false, 'data': {'type': 'login', 'title': 't', 'tags': ['个人']}},
      'suggested': {'type': 'login', 'title': 't'},
    });
    final resolution = ConflictResolution.fields({ConflictField.tags: ConflictSide.remote});
    expect(resolution.isValidFor(detail), isTrue);
    expect((resolution.toJson()['choices'] as List).single, {'field': 'tags', 'side': 'remote'});
  });

  test('ItemData 的 tags/category 与冲突字段键名一致', () {
    // `ConflictVersion.value` 用 `field.name` 取 JSON 键，因此 ItemData.toJson 必须
    // 使用同样的键名，否则冲突页会显示成空值。
    const data = ItemData(kind: ItemKind.login, title: 't', tags: ['工作'], category: '金融');
    final json = data.toJson();
    expect(json[ConflictField.tags.name], ['工作']);
    expect(json[ConflictField.category.name], '金融');
  });
}
