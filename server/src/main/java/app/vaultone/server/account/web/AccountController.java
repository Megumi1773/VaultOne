package app.vaultone.server.account.web;

import app.vaultone.server.account.service.AccountService;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.proto.AccountResponse;
import app.vaultone.server.proto.BindInviteRequest;
import app.vaultone.server.proto.ChangeCredentialsRequest;
import app.vaultone.server.proto.ChangeCredentialsResponse;
import app.vaultone.server.proto.UpdateProfileRequest;
import app.vaultone.server.security.Approved;
import app.vaultone.server.web.OkResponse;
import app.vaultone.server.web.RequestIds;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 账户路由：读取账户、变更凭据、注销。逐条对齐 Rust {@code routes_account.rs}。 */
@RestController
@RequestMapping("/v1/account")
public class AccountController {
  private final AccountService account;
  private final ServerKeys keys;

  public AccountController(AccountService account, ServerKeys keys) {
    this.account = account;
    this.keys = keys;
  }

  @GetMapping
  public AccountResponse get(Approved approved) {
    return account.getAccount(approved);
  }

  @PutMapping("/credentials")
  public ChangeCredentialsResponse changeCredentials(
      Approved approved, @RequestBody ChangeCredentialsRequest req, HttpServletRequest request) {
    return account.changeCredentials(
        approved, req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
  }

  /** 更新账户资料（昵称 / 头像地址，计划书 §8.2）。返回更新后的完整账户信息。 */
  @PutMapping("/profile")
  public AccountResponse updateProfile(
      Approved approved, @RequestBody UpdateProfileRequest req, HttpServletRequest request) {
    return account.updateProfile(
        approved, req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
  }

  /** 补填邀请人邀请码（计划书 §9）。一次性绑定，绑定后不可更改。 */
  @PostMapping("/invite")
  public AccountResponse bindInvite(
      Approved approved, @RequestBody BindInviteRequest req, HttpServletRequest request) {
    return account.bindInvite(
        approved, req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
  }

  @DeleteMapping
  public OkResponse delete(Approved approved, HttpServletRequest request) {
    account.deleteAccount(
        approved, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return new OkResponse(true);
  }
}
