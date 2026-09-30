package app.vaultone.server.identity.web;

import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.service.DeviceService;
import app.vaultone.server.identity.service.IdentityService;
import app.vaultone.server.proto.DeviceOut;
import app.vaultone.server.proto.VerifyDeviceRequest;
import app.vaultone.server.security.Approved;
import app.vaultone.server.security.Authed;
import app.vaultone.server.web.ApprovedResponse;
import app.vaultone.server.web.OkResponse;
import app.vaultone.server.web.RequestIds;
import jakarta.servlet.http.HttpServletRequest;
import java.util.List;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 设备路由：自身设备、列表、验证、批准、撤销。逐条对齐 Rust {@code routes_account.rs}。 */
@RestController
@RequestMapping("/v1/devices")
public class DeviceController {
  private final DeviceService devices;
  private final IdentityService identity;
  private final ServerKeys keys;

  public DeviceController(DeviceService devices, IdentityService identity, ServerKeys keys) {
    this.devices = devices;
    this.identity = identity;
    this.keys = keys;
  }

  /** 新设备 OTP 验证；成功返回 {@code {"approved":true}}。 */
  @PostMapping("/self/verify")
  public ApprovedResponse verify(
      Authed authed, @RequestBody VerifyDeviceRequest req, HttpServletRequest request) {
    identity.verifyDevice(
        authed, req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return new ApprovedResponse(true);
  }

  @GetMapping
  public List<DeviceOut> list(Approved approved) {
    return devices.listDevices(approved);
  }

  @GetMapping("/self")
  public DeviceOut self(Authed authed) {
    return devices.deviceSelf(authed);
  }

  @PostMapping("/{id}/approve")
  public OkResponse approve(
      Approved approved, @PathVariable("id") String deviceId, HttpServletRequest request) {
    devices.approveDevice(
        approved, deviceId, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return new OkResponse(true);
  }

  @DeleteMapping("/{id}")
  public OkResponse revoke(
      Approved approved, @PathVariable("id") String deviceId, HttpServletRequest request) {
    devices.revokeDevice(
        approved, deviceId, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return new OkResponse(true);
  }
}
