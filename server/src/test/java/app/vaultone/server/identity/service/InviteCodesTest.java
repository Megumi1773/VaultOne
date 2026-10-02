package app.vaultone.server.identity.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import app.vaultone.server.validate.WireValidation;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.Test;

/** 邀请码的生成与规范化（计划书 §8.1 / §9）。 */
class InviteCodesTest {

  @Test
  void generatesCodesOfFixedLengthFromTheUnambiguousAlphabet() {
    Set<String> seen = new HashSet<>();
    for (int i = 0; i < 200; i++) {
      String code = InviteCodes.generate();
      assertThat(code).hasSize(InviteCodes.LENGTH);
      // 易混字符必须一个都不出现：邀请码是要念给人、或让人手抄的。
      assertThat(code)
          .doesNotContain("0")
          .doesNotContain("O")
          .doesNotContain("1")
          .doesNotContain("I")
          .doesNotContain("L");
      assertThat(code).matches("[A-Z2-9]+");
      seen.add(code);
    }
    // 200 次生成不该有重复（59 bit 熵）。
    assertThat(seen).hasSize(200);
  }

  @Test
  void normalizeIsForgivingAboutWhatUsersActuallyPaste() {
    String canonical = "ABCD2345EFGH";
    for (String raw :
        new String[] {
          canonical, " abcd2345efgh ", "ABCD-2345-EFGH", "ABCD 2345 EFGH", "\tABCD2345EFGH\n"
        }) {
      assertThat(InviteCodes.normalize(raw)).as(raw).isEqualTo(canonical);
    }
  }

  @Test
  void normalizeRejectsWrongLengthAndWrongAlphabet() {
    assertThatThrownBy(() -> InviteCodes.normalize(null))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> InviteCodes.normalize("   "))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> InviteCodes.normalize("ABC"))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> InviteCodes.normalize("ABCD2345EFGHX"))
        .isInstanceOf(WireValidation.ValidationException.class);
    // 易混字符不在字母表里：用户抄错时给出「格式不正确」而不是去查一个永远查不到的码。
    assertThatThrownBy(() -> InviteCodes.normalize("ABCD2345EFG0"))
        .isInstanceOf(WireValidation.ValidationException.class);
    assertThatThrownBy(() -> InviteCodes.normalize("ABCD2345EFGI"))
        .isInstanceOf(WireValidation.ValidationException.class);
  }

  @Test
  void generatedCodesAlwaysNormalizeToThemselves() {
    for (int i = 0; i < 50; i++) {
      String code = InviteCodes.generate();
      assertThatCode(() -> assertThat(InviteCodes.normalize(code)).isEqualTo(code))
          .doesNotThrowAnyException();
    }
  }
}
