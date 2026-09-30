package app.vaultone.server.proto;

import java.util.List;

public record PullResponse(List<RemoteItem> items, long cursor, boolean hasMore, Long vkGen) {
  public PullResponse {
    items = items == null ? null : List.copyOf(items);
  }

  @Override
  public List<RemoteItem> items() {
    return items;
  }
}
