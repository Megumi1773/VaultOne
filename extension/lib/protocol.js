// 与 VaultOne 桌面端通信（经 Native Messaging 宿主转发）。协议与认证见 crates/vault-core/src/browser.rs。
//
// 扩展只保存一把配对密钥（chrome.storage.local），不保存任何保险库数据；每次调用都带 HMAC-SHA256 签名。

export const HOST = 'app.vaultone.browser';
const MAC_DOMAIN = 'vaultone-browser/v1\n';
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const enc = new TextEncoder();

export function toB64(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function fromB64(s) {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** 配对码：SHA-256(密钥) 前 40 bit → Crockford Base32，`XXXX-XXXX`。与 Rust `browser::pairing_code` 一致。 */
export async function pairingCode(keyB64) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', fromB64(keyB64)));
  let bits = 0n;
  for (let i = 0; i < 5; i++) bits = (bits << 8n) | BigInt(d[i]);
  let code = '';
  for (let i = 7; i >= 0; i--) code += ALPHABET[Number((bits >> BigInt(i * 5)) & 31n)];
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** 请求 MAC。与 Rust `browser::compute_mac` 一致。 */
export async function computeMac(keyB64, clientId, nonce, ts, body) {
  const key = await crypto.subtle.importKey('raw', fromB64(keyB64), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const msg = enc.encode(`${MAC_DOMAIN}${clientId}\n${nonce}\n${ts}\n${body}`);
  return toB64(new Uint8Array(await crypto.subtle.sign('HMAC', key, msg)));
}

function browserName() {
  const brands = navigator.userAgentData?.brands?.map((b) => b.brand) ?? [];
  const name = brands.find((b) => /Edge|Brave|Opera|Chromium|Chrome/.test(b) && b !== 'Chromium') ?? 'Chrome';
  const os = navigator.userAgentData?.platform || '';
  return os ? `${name}（${os}）` : name;
}

/** 本扩展实例的身份：首次使用时生成（仅本地，卸载扩展即消失）。 */
export async function identity() {
  const { identity } = await chrome.storage.local.get('identity');
  if (identity) return identity;
  const fresh = {
    clientId: hex(crypto.getRandomValues(new Uint8Array(16))),
    key: toB64(crypto.getRandomValues(new Uint8Array(32))),
    paired: false,
  };
  await chrome.storage.local.set({ identity: fresh });
  return fresh;
}

async function native(message) {
  try {
    return await chrome.runtime.sendNativeMessage(HOST, message);
  } catch (e) {
    // 宿主未登记（桌面端未安装 / 未在设置中启用浏览器集成）
    return { ok: false, code: 'host_missing', message: '未找到 VaultOne 桌面端。请安装并打开 VaultOne，在「设置 → 浏览器扩展」中启用集成。' };
  }
}

export async function hello() {
  const id = await identity();
  const r = await native({ type: 'hello', clientId: id.clientId });
  if (r?.ok && r.paired === false && id.paired) {
    // 桌面端已撤销本浏览器
    await chrome.storage.local.set({ identity: { ...id, paired: false } });
  }
  return r;
}

/** 发起配对。桌面端会弹窗显示配对码，用户核对一致后批准。 */
export async function pair() {
  let id = await identity();
  if (id.paired) {
    // 重新配对时换新密钥，旧密钥作废
    id = { ...id, key: toB64(crypto.getRandomValues(new Uint8Array(32))), paired: false };
    await chrome.storage.local.set({ identity: id });
  }
  const r = await native({ type: 'pair', clientId: id.clientId, name: browserName(), key: id.key });
  if (r?.ok) await chrome.storage.local.set({ identity: { ...id, paired: true } });
  return r;
}

/** 已认证调用。`op` 见 Rust `browser::Op`。 */
export async function call(op) {
  const id = await identity();
  const body = JSON.stringify(op);
  const nonce = hex(crypto.getRandomValues(new Uint8Array(16)));
  const ts = Math.floor(Date.now() / 1000);
  const mac = await computeMac(id.key, id.clientId, nonce, ts, body);
  const r = await native({ type: 'call', clientId: id.clientId, nonce, ts, body, mac });
  if (r && (r.code === 'unpaired' || r.code === 'unauthorized') && id.paired) {
    await chrome.storage.local.set({ identity: { ...id, paired: false } });
  }
  return r;
}
