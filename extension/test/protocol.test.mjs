// 扩展与桌面端的配对码 / MAC 算法必须一致：期望值来自 Rust `vault_core::browser` 的单元测试。
// 运行：node --test extension/test
import assert from 'node:assert/strict';
import test from 'node:test';

import { computeMac, pairingCode } from '../lib/protocol.js';

const KEY = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

test('pairing code matches Rust', async () => {
  assert.equal(await pairingCode(KEY), 'CC6W-TAB6');
});

test('mac matches Rust', async () => {
  assert.equal(await computeMac(KEY, 'c1', 'nonce-000000000001', 1700000000, '{"op":"match","url":"https://example.com"}'), '/OZlkRpUPBhuPSw89NWc0zuRodBMKuhm1KImMX2aAxA=');
});
