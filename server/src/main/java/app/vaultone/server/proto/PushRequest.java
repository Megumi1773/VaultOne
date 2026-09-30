package app.vaultone.server.proto;

import java.util.List;

public record PushRequest(List<PushItem> items) {
  public PushRequest {
    items = items == null ? null : List.copyOf(items);
  }

  @Override
  public List<PushItem> items() {
    return items;
  }
}
