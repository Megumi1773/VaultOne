// 扩展后台（MV3 service worker）：内容脚本与弹窗的唯一出口。
//
// 防钓鱼关键点：发给桌面端的页面 URL 一律取自浏览器提供的 `sender.url`（发起请求的那个框架的真实地址）
// 或当前标签页地址，从不采信页面脚本自报的 URL；桌面端再按 eTLD+1 严格匹配后才释放凭据。

import { call, hello, pair } from './lib/protocol.js';

const PROMPT_KEY = (tabId) => `prompt:${tabId}`;

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

/** 让标签页内所有框架尝试填充指定条目；每个框架各自以自身地址向桌面端取凭据。 */
async function fillTab(tabId, itemId) {
  await chrome.tabs.sendMessage(tabId, { type: 'vo:doFill', id: itemId }).catch(() => {});
}

async function fillBestMatch(tab) {
  if (!tab?.url) return;
  const r = await call({ op: 'match', url: tab.url });
  if (r?.ok && r.items.length > 0) await fillTab(tab.id, r.items[0].id);
}

chrome.commands.onCommand.addListener(async (command) => {
  if (command === 'fill-login') await fillBestMatch(await activeTab());
});

// 标签页关闭时丢弃待保存的凭据
chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove(PROMPT_KEY(tabId)));

async function handle(msg, sender) {
  const frameUrl = sender.url; // 内容脚本所在框架的真实地址
  const tabId = sender.tab?.id;
  switch (msg.type) {
    // —— 弹窗 ——
    case 'vo:status':
      return hello();
    case 'vo:pair':
      return pair();
    case 'vo:popupMatch': {
      const tab = await activeTab();
      if (!tab?.url || !/^https?:/.test(tab.url)) return { ok: true, items: [], unsupported: true };
      return call({ op: 'match', url: tab.url });
    }
    case 'vo:popupFill': {
      const tab = await activeTab();
      await fillTab(tab.id, msg.id);
      return { ok: true };
    }
    case 'vo:popupTotp': {
      const tab = await activeTab();
      return call({ op: 'totp', url: tab.url, id: msg.id });
    }

    // —— 内容脚本 ——
    case 'vo:getCreds':
      return call({ op: 'fill', url: frameUrl, id: msg.id });
    case 'vo:submitted': {
      if (!msg.password || tabId == null) return { ok: true };
      const r = await call({ op: 'check', url: frameUrl, username: msg.username ?? '', password: msg.password });
      if (r?.ok && (r.result === 'new' || r.result === 'update')) {
        // 只保存在浏览器会话内存（storage.session），不落盘；用户处理或标签页关闭即删除
        const prompt = { url: frameUrl, username: msg.username ?? '', password: msg.password, result: r.result, title: r.title ?? null, at: Date.now() };
        await chrome.storage.session.set({ [PROMPT_KEY(tabId)]: prompt });
        await chrome.tabs.sendMessage(tabId, { type: 'vo:showPrompt', prompt: publicPrompt(prompt) }, { frameId: 0 }).catch(() => {});
      }
      return { ok: true };
    }
    case 'vo:pendingPrompt': {
      if (tabId == null || sender.frameId !== 0) return { ok: true, prompt: null };
      const key = PROMPT_KEY(tabId);
      const { [key]: prompt } = await chrome.storage.session.get(key);
      // 跳转后 2 分钟内仍提示（登录表单提交后通常会跳转）
      if (!prompt || Date.now() - prompt.at > 120_000) return { ok: true, prompt: null };
      return { ok: true, prompt: publicPrompt(prompt) };
    }
    case 'vo:savePrompt': {
      const key = PROMPT_KEY(tabId);
      const { [key]: prompt } = await chrome.storage.session.get(key);
      await chrome.storage.session.remove(key);
      if (!prompt) return { ok: false, message: '保存请求已过期' };
      return call({ op: 'save', url: prompt.url, username: prompt.username, password: prompt.password });
    }
    case 'vo:dismissPrompt':
      await chrome.storage.session.remove(PROMPT_KEY(tabId));
      return { ok: true };
    default:
      return { ok: false, code: 'invalid_input' };
  }
}

/** 发给页面的提示信息不含密码。 */
function publicPrompt(p) {
  return { username: p.username, result: p.result, title: p.title, host: new URL(p.url).host };
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // 只接受本扩展自身（内容脚本 / 弹窗）的消息
  if (sender.id !== chrome.runtime.id) return false;
  handle(msg, sender).then(sendResponse, (e) => sendResponse({ ok: false, message: String(e) }));
  return true;
});
