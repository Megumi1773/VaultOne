package app.vaultone.server;

import static org.assertj.core.api.Assertions.*;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.FeedbackProperties;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.ops.FeedbackConsole;
import app.vaultone.server.feedback.service.FeedbackRules;
import jakarta.validation.Validation;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class FeedbackRulesTest {
  private FeedbackDtos.Create create(String content, String contact, Boolean consent) {
    return new FeedbackDtos.Create(UUID.randomUUID().toString(), "bug", content, contact, consent);
  }

  @Test
  void consentAndNormalization() {
    var request = FeedbackRules.create(create("  内容\n ", "  ", true));
    assertThat(request.content()).isEqualTo("内容");
    assertThat(request.contact()).isNull();
    for (Boolean consent : new Boolean[] {null, false}) {
      assertThatThrownBy(() -> FeedbackRules.create(create("内容", null, consent)))
          .isInstanceOf(ApiException.class);
    }
  }

  @Test
  void utf16AndControlCharactersAreBounded() {
    FeedbackRules.create(create("😀".repeat(2000), "a".repeat(200), true));
    for (String value : List.of("", " \n\t", "😀".repeat(2001), "foo\0bar", "\u001b[31m")) {
      assertThatThrownBy(() -> FeedbackRules.create(create(value, null, true)))
          .isInstanceOf(ApiException.class);
    }
    assertThatThrownBy(() -> FeedbackRules.create(create("内容", "a".repeat(201), true)))
        .isInstanceOf(ApiException.class);
  }

  @Test
  void identifiersAndPaginationCannotInjectPathsOrQueries() {
    for (String id :
        List.of("../account", "1-1-1-1-1", "", UUID.randomUUID().toString().toUpperCase())) {
      assertThatThrownBy(() -> FeedbackRules.id(id)).isInstanceOf(ApiException.class);
    }
    assertThatThrownBy(() -> FeedbackRules.page(0L, 20)).isInstanceOf(ApiException.class);
    assertThatThrownBy(() -> FeedbackRules.page(null, 51)).isInstanceOf(ApiException.class);
    assertThatThrownBy(() -> FeedbackRules.page(null, 0)).isInstanceOf(ApiException.class);
    assertThatThrownBy(() -> FeedbackRules.operator("ops\nforged"))
        .isInstanceOf(ApiException.class);
  }

  @Test
  void resolvedRequiresReplyAndValidVersion() {
    FeedbackRules.handle(new FeedbackDtos.Handle(1, "resolved", "已修复"));
    assertThatThrownBy(() -> FeedbackRules.handle(new FeedbackDtos.Handle(1, "resolved", null)))
        .isInstanceOf(ApiException.class);
    assertThatThrownBy(() -> FeedbackRules.handle(new FeedbackDtos.Handle(0, "open", null)))
        .isInstanceOf(ApiException.class);
    assertThatThrownBy(() -> FeedbackRules.handle(new FeedbackDtos.Handle(1, "unknown", "reply")))
        .isInstanceOf(ApiException.class);
  }

  @Test
  void configurationHasFiniteBoundsAndRecordsRedact() {
    try (var factory = Validation.buildDefaultValidatorFactory()) {
      assertThat(factory.getValidator().validate(new FeedbackProperties(180, 200, 10))).isEmpty();
      assertThat(factory.getValidator().validate(new FeedbackProperties(0, 1001, 101))).hasSize(3);
    }
    assertThat(create("sensitive", "contact@example.test", true).toString())
        .doesNotContain("sensitive", "contact@");
    assertThat(new FeedbackDtos.Handle(1, "resolved", "sensitive").toString())
        .doesNotContain("sensitive");
  }

  @Test
  void invalidConsoleInputFailsBeforeConnectingAndDoesNotEchoText() {
    for (String input :
        List.of(
            "secret-not-json",
            "{}",
            "x".repeat(32769),
            "{\"action\":\"unknown\",\"account_id\":\"secret\"}")) {
      var output = new ByteArrayOutputStream();
      int status =
          FeedbackConsole.run(
              new String[0],
              new ByteArrayInputStream(input.getBytes(StandardCharsets.UTF_8)),
              new PrintStream(output));
      assertThat(status).isEqualTo(2);
      assertThat(output.toString(StandardCharsets.UTF_8))
          .contains("bad_request")
          .doesNotContain("secret", "Exception");
    }
  }
}
