package app.vaultone.server.feedback;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties("vaultone.feedback")
public record FeedbackProperties(
    @Min(1) @Max(365) int retentionDays,
    @Min(1) @Max(1000) int maxActivePerAccount,
    @Min(1) @Max(100) int maxPerDay) {}
