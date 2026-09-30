package app.vaultone.server.proto;

/** DTO 构造校验辅助：非 Option 字段缺失/为 null 一律拒绝。 */
final class Dto {
  static void require(Object value, String field) {
    if (value == null) {
      throw new IllegalArgumentException(field + " 不能为 null");
    }
  }

  static void requireAll(Object... pairs) {
    for (int i = 0; i < pairs.length; i += 2) {
      require(pairs[i], (String) pairs[i + 1]);
    }
  }

  private Dto() {}
}
