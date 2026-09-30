package app.vaultone.server.proto;

import java.util.List;

public record PushResponse(List<PushResult> results) {
  public PushResponse {
    results = results == null ? null : List.copyOf(results);
  }

  @Override
  public List<PushResult> results() {
    return results;
  }
}
