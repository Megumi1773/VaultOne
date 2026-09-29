package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import jakarta.el.ExpressionFactory;
import jakarta.validation.Validation;
import jakarta.validation.constraints.Min;
import org.junit.jupiter.api.Test;

/** 真正的Bean Validation与EL插值，不替换成不支持表达式的消息插值器。 */
class ValidationTest {
  record Quantity(@Min(value = 2, message = "min={value}; actual=${validatedValue}") int count) {}

  @Test
  void expresslyInterpolatesConstraintAttributesAndExpressionLanguage() {
    assertThat(ExpressionFactory.newInstance().getClass().getName())
        .startsWith("org.glassfish.expressly.");
    try (var factory = Validation.buildDefaultValidatorFactory()) {
      var validator = factory.getValidator();
      var violations = validator.validate(new Quantity(1));
      assertThat(violations).hasSize(1);
      assertThat(violations.iterator().next().getMessage()).isEqualTo("min=2; actual=1");
      assertThat(validator.validate(new Quantity(2))).isEmpty();
    }
  }
}
