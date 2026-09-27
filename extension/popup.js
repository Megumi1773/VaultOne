// 扩展弹窗：连接状态 → 配对 → 当前网站的匹配条目（填充 / 复制验证码）。
import { identity, pairingCode } from './lib/protocol.js';

const view = document.getElementById('view');
const send = (msg) => chrome.runtime.sendMessage(msg);

function render(html) {
  view.innerHTML = html;
}

function text(sel, value) {
  view.querySelector(sel).textContent = value;
}

async function showPairing() {
  const id = await identity();
  render(`
    <p>此浏览器尚未与 VaultOne 桌面端配对。</p>
    <p class="muted">点击配对后，桌面端会弹出确认窗口。请核对两边显示的配对码一致后再批准。</p>
    <div class="code"></div>
    <button class="primary" id="pair">配对</button>`);
  text('.code', await pairingCode(id.key));
  view.querySelector('#pair').onclick = async (e) => {
    e.target.disabled = true;
    e.target.textContent = '请在桌面端确认…';
    const r = await send({ type: 'vo:pair' });
    if (r?.ok) return main();
    // 重新配对会换新密钥，刷新显示的配对码
    await showPairing();
    const p = document.createElement('p');
    p.className = 'muted';
    p.textContent = r?.message ?? '配对失败';
    view.appendChild(p);
  };
}

async function copyTotp(id, button) {
  const r = await send({ type: 'vo:popupTotp', id });
  if (!r?.ok || !r.totp) return;
  await navigator.clipboard.writeText(r.totp.code);
  button.textContent = `已复制（${r.totp.remaining}s）`;
  setTimeout(() => (button.textContent = '验证码'), 2000);
}

async function showMatches() {
  const r = await send({ type: 'vo:popupMatch' });
  if (!r?.ok) return render(`<p class="muted"></p>`), text('.muted', r?.message ?? '读取失败');
  if (r.unsupported) return render('<p class="muted">当前页面不支持自动填充。</p>');
  if (r.items.length === 0) {
    return render(`<p>没有与此网站匹配的登录条目。</p><p class="hint">登录后 VaultOne 会提示保存。为防钓鱼，只有与条目网址同一注册域名的页面才会出现在这里。</p>`);
  }
  render('<ul></ul><p class="hint">快捷键 Ctrl+Shift+L（macOS ⌘⇧L）直接填充第一项。</p>');
  const ul = view.querySelector('ul');
  for (const item of r.items) {
    const li = document.createElement('li');
    li.innerHTML = `<div class="text"><div class="title"></div><div class="user"></div></div>`;
    li.querySelector('.title').textContent = item.title;
    li.querySelector('.user').textContent = item.username || '（无用户名）';
    if (item.hasTotp) {
      const b = document.createElement('button');
      b.textContent = '验证码';
      b.onclick = () => copyTotp(item.id, b);
      li.appendChild(b);
    }
    const fill = document.createElement('button');
    fill.textContent = '填充';
    fill.onclick = async () => {
      await send({ type: 'vo:popupFill', id: item.id });
      window.close();
    };
    li.appendChild(fill);
    ul.appendChild(li);
  }
}

async function main() {
  const s = await send({ type: 'vo:status' });
  if (!s?.ok) return render('<p class="muted"></p>'), text('.muted', s?.message ?? '无法连接 VaultOne 桌面端');
  if (s.locked) return render('<p>VaultOne 已锁定。</p><p class="muted">请在桌面端解锁后重试（全局快捷键 Ctrl+Shift+Space 可快速唤起）。</p>');
  if (!s.paired) return showPairing();
  return showMatches();
}

main();
