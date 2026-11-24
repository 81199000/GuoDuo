// 手机号 + 验证码登录（红果 App passport），含风控要求的「上行短信」二次验证。
// 流程照绿果TV（lvguo-tv web/internal/lvguoplay/phone_login.go）：同一台新注册设备、同一组 cookie 贯穿 发码 → 登录 → 二次验证。
// 隐私：手机号 / 验证码只发给红果 passport（按 App 协议 xor5 编码），不落盘、不打日志。
const { signRaw } = require('./upstream/app-source.js');
const { registerPlaybackDevice } = require('./upstream/playback-device.js');
const { requestJson } = require('./upstream/app-source.js');

const BASE = 'https://api5-normal-lq.fqnovel.com';
const UA = 'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
const fail = (m, code) => Object.assign(new Error(m), { code });
const xor5 = s => { const b = Buffer.from(String(s), 'utf8'); let h = ''; for (const x of b) h += (x ^ 5).toString(16).padStart(2, '0'); return h; };
const hexRand = n => require('node:crypto').randomBytes(n).toString('hex');

function normalizeCN(raw) {
  let s = String(raw || '').replace(/\D/g, '');
  if (s.startsWith('86') && s.length === 13) s = s.slice(2);
  return s.length === 11 && s[0] === '1' ? `+86${s}` : '';
}

let state = null;   // { device, cookies: Map, token, phone, code, mfa }

function query(device) {
  return { ac: 'wifi', aid: '8662', app_name: 'novelread', channel: 'update_64', device_brand: 'Redmi', device_id: device.device_id,
    device_platform: 'android', device_type: '25053RT47C', dpi: '520', iid: device.iid, language: 'zh', manifest_version_code: '73532',
    os: 'android', os_api: '36', os_version: '16', resolution: '1280*2772', ssmix: 'a', update_version_code: '73532',
    version_code: '73532', version_name: '7.3.5.32', cdid: device.cdid, openudid: device.openudid };
}

async function post(path, form) {
  const axios = require('axios');
  const body = Buffer.from(new URLSearchParams(form).toString());
  const dev = state.device;
  const khronos = Math.floor(Date.now() / 1000), base = Date.now();
  let raw, url, ticket;
  for (let n = 0; n < 128; n++) {
    ticket = base + n;
    raw = signRaw.pythonUrlEncode({ ...query(dev), _rticket: String(ticket) });
    url = `${BASE}${path}?${raw}`;
    if (signRaw.branchOf(url, body, khronos) === 0) break;
    if (n === 127) throw fail('请求签名失败', 'SIGN');
  }
  const headers = {
    'User-Agent': UA, Accept: 'application/json', 'X-XS-From-Web': '0', 'Sdk-Version': '2', 'Passport-Sdk-Version': '5051452',
    'X-Vc-Bdturing-Sdk-Version': '4.0.3.cn', Lc: '101', 'X-SS-DP': '8662', 'X-Tt-Store-Region': state.cookies.get('store-region') || 'cn',
    'X-Tt-Store-Region-Src': 'did', 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'X-Khronos': String(khronos), 'X-SS-Req-Ticket': String(ticket), 'X-Helios': signRaw.helios(khronos),
    'X-Medusa': signRaw.buildMedusa(url, body, khronos, { device_id: dev.device_id, version_name: '7.3.5.32' }),
    'X-Gorgon': signRaw.xGorgon(raw, body, khronos, Math.floor(Math.random() * 65536)), 'X-SS-STUB': signRaw.md5(body),
    ...(state.token ? { 'X-Tt-Token': state.token } : {}),
    ...(state.cookies.size ? { Cookie: [...state.cookies].map(([k, v]) => `${k}=${v}`).join('; ') } : {}),
  };
  const r = await axios({ url, method: 'POST', data: body, headers, timeout: 20000, maxRedirects: 0, responseType: 'text',
    transformResponse: [d => d], validateStatus: () => true }).catch(() => { throw fail('红果账号服务连接失败，请稍后重试', 'NETWORK'); });
  if (r.status !== 200) throw fail(`红果账号服务暂不可用（${r.status}）`, 'HTTP');
  const set = r.headers?.['set-cookie'];
  for (const line of Array.isArray(set) ? set : set ? [set] : []) {
    const pair = String(line).split(';', 1)[0], at = pair.indexOf('=');
    if (at > 0) state.cookies.set(pair.slice(0, at).trim(), pair.slice(at + 1).trim());
  }
  const t = r.headers?.['x-tt-token']; if (t) state.token = String(t);
  try { return JSON.parse(r.data); } catch (_) { throw fail('红果账号服务返回异常', 'BAD_RESPONSE'); }
}

const data = p => (p && typeof p.data === 'object' && p.data) || {};
const errCode = p => String(data(p).error_code ?? p?.error_code ?? '');
const ok = p => p?.message === 'success' && (!errCode(p) || errCode(p) === '0');
function failure(p, fallback) {
  let m = String(data(p).description || p?.description || '').trim();
  if (!m || /[\r\n]|http/.test(m) || m.length > 120) m = fallback;
  return fail(m.replace(/[0-9]{7,}/g, '***'), 'PASSPORT');
}
const form = phone => ({ mobile: xor5(phone), account_sdk_source: 'app', passport_support_flow: 'captcha,verify', mix_mode: '1' });

async function sendCode(phone) {
  const n = normalizeCN(phone);
  if (!n) throw fail('请输入正确的 11 位手机号', 'INPUT');
  if (!state || state.phone !== n) {
    const id = await registerPlaybackDevice(requestJson);   // 每次登录一台新设备（同绿果）
    state = { device: { ...id, openudid: hexRand(8) }, cookies: new Map([['install_id', id.iid]]), token: '', phone: n, code: '', mfa: null };
  }
  const r = await post('/passport/mobile/send_code/v1/', { ...form(n), auto_read: '0', unbind_exist: '34', type: xor5('24') });
  if (!ok(r)) throw failure(r, '验证码发送失败');
  state.code = ''; state.mfa = null;
  return { sent: true };
}

function parseMFA(d) {
  const m = { encryptUID: String(d.encrypt_uid || ''), codeKey: String(d.sms_code_key || ''), logID: String(d.event_params?.log_id || '') };
  for (const w of Array.isArray(d.verify_ways) ? d.verify_ways : []) {
    if (w?.verify_way === 'upsms' || w?.sms_content) { m.content = String(w.sms_content || ''); m.number = String(w.channel_mobile || ''); break; }
  }
  return m.encryptUID && m.codeKey && m.number && m.content ? m : null;
}

function session() {
  if (!state.cookies.get('sessionid') && !state.cookies.get('sessionid_ss')) throw fail('登录未返回会话，请重试', 'NO_SESSION');
  const cookie = [...state.cookies].map(([k, v]) => `${k}=${v}`).join('; ');
  const device = state.device;
  state = null;
  return { cookie, device };
}

async function smsLogin(ticket = '') {
  const f = { ...form(state.phone), code: xor5(state.code) };
  if (ticket) Object.assign(f, { passport_mfa_retry_tag: '1', sms_code_key: xor5(state.mfa.codeKey), verify_ticket: ticket });
  return post('/passport/mobile/sms_login/', f);
}

/** 用验证码登录：成功回 { cookie, device }；要上行短信验证回 { mfa: { number, content } } */
async function login(code) {
  if (!state?.phone) throw fail('请先获取验证码', 'INPUT');
  if (!/^[0-9]{4,8}$/.test(String(code || ''))) throw fail('请输入短信里的验证码', 'INPUT');
  state.code = String(code);
  const r = await smsLogin();
  if (!ok(r)) {
    const m = parseMFA(data(r));
    if (m) { state.mfa = m; return { mfa: { number: m.number, content: m.content } }; }
    throw failure(r, '登录失败，请重试');
  }
  return session();
}

/** 发完验证短信后调：服务端还没收到回 { pending: true } */
async function verifyMFA() {
  const m = state?.mfa;
  if (!m) throw fail('验证已结束，请重新获取验证码', 'INPUT');
  const r = await post('/passport/upsms/verify/', { encrypt_uid: m.encryptUID, verify_ticket: '', verify_scene: 'sms_login', verify_reason: 'ato',
    copywriting_key: 'sms_login', ies_safety_diversion_tag: 'mfa', new_verify_flow: '', new_authn_sdk_version: '1.1.31',
    new_authn_sdk_verify_reason: 'ato', new_authn_sdk_verify_scene: 'sms_login', request_tag_from: 'h5',
    biz_params: JSON.stringify({ passport_mfa_retry_tag: '1', sms_code_key: m.codeKey }), new_authn_sdk_log_id: m.logID });
  if (errCode(r) === '1045') return { pending: true };
  const expired = p => /过期|失效|长时间未操作/.test(String(data(p).description || ''));
  if (!ok(r)) { if (expired(r)) state.mfa = null; throw expired(r) ? fail('红果已结束本次短信验证，请重新获取验证码', 'MFA_EXPIRED') : failure(r, '短信验证未通过'); }
  const ticket = String(data(r).ticket || data(r).verify_ticket || '');
  if (!ticket) throw fail('验证响应缺少登录票据', 'BAD_RESPONSE');
  const lr = await smsLogin(ticket);
  if (!ok(lr)) { if (expired(lr)) state.mfa = null; throw expired(lr) ? fail('红果已结束本次短信验证，请重新获取验证码', 'MFA_EXPIRED') : failure(lr, '验证后登录失败，请重试'); }
  return session();
}

function cancel() { state = null; }

module.exports = { normalizeCN, sendCode, login, verifyMFA, cancel, _probe: { post, setState: s => { state = s; }, xor5, form } };
