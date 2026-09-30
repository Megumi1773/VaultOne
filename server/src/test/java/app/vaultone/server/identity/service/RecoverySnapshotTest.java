package app.vaultone.server.identity.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.IdentityBootstrapRepository;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class RecoverySnapshotTest {
  @Test
  void verifiedHashAndCasGenerationComeFromOneSnapshot() {
    byte[] oldAuth = new byte[] {1, 2, 3};
    byte[] newAuth = new byte[] {4, 5, 6};
    byte[] oldHash = ServerKeys.sha256(oldAuth);
    var bootstrap = mock(IdentityBootstrapRepository.class);
    var accounts = mock(AccountContext.class);
    var audit = mock(AuditService.class);
    var mapper = mock(KeysMapper.class);
    var oldUser = user(oldHash, 1);
    var newUser = user(ServerKeys.sha256(newAuth), 2);
    when(bootstrap.recoveryLookup(any(byte[].class)))
        .thenReturn(
            Optional.of(new IdentityBootstrapRepository.RecoveryLookup("account", oldHash)));
    when(accounts.readAccount("account")).thenReturn(Optional.of(oldUser), Optional.of(newUser));

    var service = new RecoveryPersistence(bootstrap, accounts, mapper, audit);
    var pre = service.preState("alice@example.test", oldAuth, new ServerKeys(new byte[32]), null);
    assertThat(pre.recoveryAuthHash()).isEqualTo(oldHash);
    assertThat(pre.sessionEpoch()).isEqualTo(1);
    assertThat(pre.vkGen()).isEqualTo(1);
    verify(accounts, times(1)).readAccount("account");
  }

  @Test
  void oldProofCannotAuthorizeAStateAlreadyRotatedAfterLookup() {
    byte[] oldAuth = new byte[] {1, 2, 3};
    var bootstrap = mock(IdentityBootstrapRepository.class);
    var accounts = mock(AccountContext.class);
    when(bootstrap.recoveryLookup(any(byte[].class)))
        .thenReturn(
            Optional.of(
                new IdentityBootstrapRepository.RecoveryLookup(
                    "account", ServerKeys.sha256(oldAuth))));
    var changedUser = user(ServerKeys.sha256(new byte[] {4, 5, 6}), 2);
    when(accounts.readAccount("account")).thenReturn(Optional.of(changedUser));
    var service =
        new RecoveryPersistence(
            bootstrap, accounts, mock(KeysMapper.class), mock(AuditService.class));
    assertThatThrownBy(
            () ->
                service.preState("alice@example.test", oldAuth, new ServerKeys(new byte[32]), null))
        .isInstanceOf(ApiException.class)
        .satisfies(ex -> assertThat(((ApiException) ex).code()).isEqualTo("auth_failed"));
  }

  private static UserEntity user(byte[] hash, long generation) {
    var user = mock(UserEntity.class);
    when(user.getId()).thenReturn("account");
    when(user.getRecoveryAuthHash()).thenReturn(hash);
    when(user.getSessionEpoch()).thenReturn(generation);
    when(user.getVkGen()).thenReturn(generation);
    return user;
  }
}
