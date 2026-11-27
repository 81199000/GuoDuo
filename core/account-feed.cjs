// GuoDuo 自有（不是上游拷贝，同步上游不会覆盖）：登录红果账号后的「为你推荐」流、完整观看记录、云端收藏。
// 参考绿果TV 2.0.8（Amor5207/lvguo-tv，GPL-3.0）src/ink/pengfei/lvguo/net/Browse.java forYou / Account.java history、favorites。
// 登录态 cookie 来自上游 account-session.js 扫码登录 / phone-login.cjs 手机号登录（存在钥匙串 hg.account.session）。
const { signedMetadataRequest, signedAccountRequest, requestJson } = require('./upstream/app-source.js');
const { getPlaybackDevice } = require('./upstream/playback-device.js');
const { catalogCover } = require('./upstream/hongguo-app-catalog.js');
const { cleanTitle } = require('./upstream/hongguo-app-search.js');
const { meta, avatarUrl } = require('./catalog-more.cjs');

// 红果「推荐」频道固定栏目 / 方案 ID（tab_type=16；同绿果TV / aston314/hongguo-tv）
const FEED_CELL = '7294257141911650341', FEED_PLAN = '7294257258253254693';
const IDS = ['series_id', 'vid', 'book_id', 'item_id', 'video_id', 'cell_id', 'plan_id', 'recommend_group_id'];
// 1004 = 短剧，1 = 真人剧；1001 是推剧切片 / 运营位，不是能播的剧
const DRAMA_TYPES = [1, 1004];

const fail = (message, code) => Object.assign(new Error(message), { code });
const idOf = v => { const s = String(v ?? '').trim(); return /^\d{1,30}$/.test(s) && /[1-9]/.test(s) ? s : ''; };
const ms = v => { const n = Number(v) || 0; return n > 0 && n < 10_000_000_000 ? n * 1000 : n; };

function checkAccount(payload, what) {
  if (!payload || typeof payload !== 'object') throw fail(`${what}返回格式异常`, 'BAD_RESPONSE');
  const code = Number(payload.code ?? payload.Code ?? 0), msg = String(payload.message || '');
  const name = String(payload.data?.name || payload.data?.error_name || '');
  if (code === 100004 || /session_expired/i.test(msg) || /session_expired/i.test(name)) throw fail('登录已失效，请重新登录', 'SESSION_EXPIRED');
  if (code !== 0) throw fail(`${what}未完成（${code}）`, 'APP_BUSINESS');
  return payload.data || {};
}

/** 推荐流里所有剧（递归找 series_id + 标题；只留短剧，去掉切片 / 运营位）。
 *  热度 / 题材挂在外层（video_data 那层的 rec_tags、recommend_reason_list），剧本身在里层 video_detail：往下带 */
function collectDramas(value, out, seen, depth = 0, outer = null) {
  if (depth > 10 || !value || typeof value !== 'object') return;
  if (Array.isArray(value)) { for (const v of value) collectDramas(v, out, seen, depth + 1, outer); return; }
  if (value.recommend_reason_list || value.rec_tags || value.rec_text_item) outer = meta(value);
  const id = idOf(value.series_id_str || value.series_id);
  const title = cleanTitle(value.series_title || value.series_name || value.title);
  const episodes = Number(value.episode_cnt) || 0;
  if (id && title && !seen.has(id) && DRAMA_TYPES.includes(Number(value.content_type)) && episodes > 0) {
    const cover = catalogCover(value.cover || value.series_cover || '');
    if (cover) {
      seen.add(id);
      const own = meta(value);
      out.push({ series_id: id, series_title: title, cover, episode_count: episodes,
        description: cleanTitle(value.video_desc || value.series_intro), plays: Number(value.series_play_cnt) || 0,
        heat: own.heat || outer?.heat, tags: own.tags.length ? own.tags : (outer?.tags || []), badge: own.badge || outer?.badge });
    }
  }
  for (const k of Object.keys(value)) if (value[k] && typeof value[k] === 'object') collectDramas(value[k], out, seen, depth + 1, outer);
}

// 红果 7.1.9 起才下发频道（漫剧 / 真人剧）：推荐流按这个版本号发（同绿果TV feedQuery）
const FEED_VERSION = { version_code: '71932', version_name: '7.1.9.32', manifest_version_code: '71932', update_version_code: '71932', pv_player: '71932' };
const CHANNELS = ['16', '36', '39', '45'];
// 频道的栏目 / 方案 ID（推荐是固定的；漫剧 / 真人剧从 bookmall/tab 首屏拿）
const channelCells = new Map([['16', [FEED_CELL, FEED_PLAN]]]);

function withCookie(headers, cookie) { return cookie ? { ...headers, Cookie: cookie } : headers; }

/** 漫剧 / 真人剧频道首屏：bookmall/tab 给首屏几部 + 栏目 / 方案 ID + session */
async function channelFirst(channel, cookie, signal) {
  const values = { ...FEED_VERSION, bottom_tab_type: '7', landing_bottom_tab_type: '7', need_personal_recommend: '1', device_level: '3',
    screen_width_px: '1078', is_horizontal_screen: 'false', tab_type: channel, offset: '0', session_id: '', client_req_type: '1',
    tab_index: '0', video_type_preferences_str: '[]' };
  const s = signedMetadataRequest('/reading/bookapi/bookmall/tab/v1/', values);
  const j = await requestJson(s.url, { method: 'GET', headers: withCookie(s.headers, cookie), preserveLargeIntegerFields: [...IDS, 'bookstore_id', 'cell_id_str'] },
    Date.now() + 10000, signal);
  const tab = (j?.data?.tab_item || []).find(t => String(t?.tab_type) === channel);
  if (Number(j?.code) !== 0 || !tab) throw fail('推荐加载失败', 'APP_BUSINESS');
  const cell = (tab.cell_data || []).map(c => idOf(c?.cell_id_str || c?.cell_id)).find(Boolean), plan = idOf(tab.bookstore_id);
  if (cell && plan) channelCells.set(channel, [cell, plan]);
  const results = [];
  collectDramas(tab.cell_data, results, new Set());
  const session = String(tab.session_id || '');
  return { results, next: 0, session: session || 'first', hasMore: !!(cell && plan) };
}

/**
 * 红果首页推荐流：channel 16 推荐 / 36 漫剧 / 39 真人剧。带登录 cookie = 账号个性化推荐；每次请求内容都会变。
 * offset / session 用上一页返回的 next / session 续页（漫剧 / 真人剧第一次 offset 0 + 空 session = 首屏）。
 */
async function forYou({ cookie = '', channel = '16', offset = 0, session = '', signal } = {}) {
  channel = CHANNELS.includes(String(channel)) ? String(channel) : '16';
  if (channel !== '16' && (!session || !channelCells.has(channel))) return channelFirst(channel, cookie, signal);
  const [cell, plan] = channelCells.get(channel);
  const values = { ...(channel === '16' ? {} : FEED_VERSION), bottom_tab_type: '7', client_req_type: '2', client_template: '7', change_type: '0', category_id: '0',
    cell_sub_id: '0', limit: '0', need_personal_recommend: '1', video_type_preferences_str: '[]',
    cell_id: cell, plan_id: plan, tab_type: channel, offset: String(Math.max(0, Number(offset) || 0)),
    session_id: session === 'first' ? '' : String(session || ''), filter_ids: '' };
  const s = signedMetadataRequest('/reading/bookapi/bookmall/cell/change/v', values);
  const headers = cookie ? { ...s.headers, Cookie: cookie } : s.headers;
  const j = await requestJson(s.url, { method: 'GET', headers, preserveLargeIntegerFields: IDS }, Date.now() + 10000, signal);
  if (!j || Number(j.code) !== 0 || !j.data?.cell_view) throw fail('推荐加载失败', 'APP_BUSINESS');
  const results = [];
  collectDramas(j.data.cell_view.cell_data, results, new Set());
  const next = Number(j.data.next_offset) || 0;
  return { results, next, session: String(j.data.session_id || session || ''),
    hasMore: j.data.has_more === true && next > (Number(offset) || 0) };
}

/** 手机号登录：会话绑在登录那台设备上，账号接口要用它；扫码登录（官网会话）用匿名设备 */
let loginIdentity = null;
function useIdentity(identity) { loginIdentity = identity || null; }

async function accountGet(cookie, apiPath, values, signal) {
  const identity = loginIdentity || await getPlaybackDevice(requestJson, { signal });
  const s = signedAccountRequest(apiPath, values, identity);
  return requestJson(s.url, { method: 'GET', headers: { ...s.headers, Cookie: cookie }, preserveLargeIntegerFields: IDS },
    Date.now() + 12000, signal);
}

/** 完整云端观看记录（手机红果 App「观看历史」同源），按 next_offset 分页拉完；最新在前，同剧只留最新一条。 */
async function historyAll({ cookie, max = 300, signal } = {}) {
  if (!cookie) throw fail('未登录', 'NOT_SIGNED_IN');
  const rows = [];
  let offset = 0;
  for (let page = 0; page < 10 && rows.length < max; page++) {
    const data = checkAccount(await accountGet(cookie, '/reading/bookapi/read_history/list/v1/', {
      book_type: '2', limit: '0', offset: String(offset), last_min_read_timestamp_ms: '0',
      full_field: 'true', is_first_load: page === 0 ? 'true' : 'false', query_soft_deleted: 'false',
    }, signal), '读取观看记录');
    const list = Array.isArray(data.data_list) ? data.data_list : [];
    for (const row of list) {
      if (row?.is_delete) continue;
      const sid = idOf(row?.book_id_str || row?.book_id || row?.series_id), vid = idOf(row?.vid || row?.item_id);
      if (!sid || !vid) continue;
      const index = Number(row?.vid_index);
      rows.push({ series_id: sid, series_title: cleanTitle(row?.series_title || row?.book_name) || `剧集 ${sid}`,
        cover: catalogCover(row?.series_cover_url || row?.thumb_url || row?.cover || ''), episode_id: vid,
        vid_index: Number.isSafeInteger(index) && index > 0 ? index : 0,
        currentTime: Math.max(0, (Number(row?.current_play_position ?? row?.current_play_time) || 0) / 1000),
        duration: Math.max(0, (Number(row?.duration ?? row?.current_total_time) || 0) / 1000),
        total: Math.max(0, Number(row?.episode_cnt || row?.episode_count) || 0),
        updatedAt: ms(row?.read_timestamp_ms || row?.last_watch_time) });
    }
    const next = Number(data.next_offset);
    if (data.has_more !== true || !Number.isFinite(next) || next <= offset || !list.length) break;
    offset = next;
  }
  rows.sort((a, b) => b.updatedAt - a.updatedAt);
  const seen = new Set();
  return rows.filter(r => !seen.has(r.series_id) && seen.add(r.series_id)).slice(0, max);
}

/** 云端收藏（红果 App「追剧」书架），按收藏时间新→旧。 */
async function favorites({ cookie, signal } = {}) {
  if (!cookie) throw fail('未登录', 'NOT_SIGNED_IN');
  const data = checkAccount(await accountGet(cookie, '/reading/bookapi/bookshelf/video/info/v1/', { offset: '0', count: '0' }, signal), '读取收藏');
  const list = Array.isArray(data.video_shelf_info) ? data.video_shelf_info : [];
  const out = [], seen = new Set();
  for (const row of list) {
    const v = row?.video_data && typeof row.video_data === 'object' ? row.video_data : row;
    const sid = idOf(v?.series_id_str || v?.series_id || row?.series_id || row?.book_id);
    if (!sid || seen.has(sid)) continue;
    seen.add(sid);
    out.push({ series_id: sid, series_title: cleanTitle(row?.series_title || v?.title || v?.series_title) || `剧集 ${sid}`,
      cover: catalogCover(row?.series_cover_url || v?.cover_url || v?.cover || v?.thumb_url || ''),
      episode_count: Math.max(0, Number(v?.episode_cnt) || 0), collectedAt: ms(row?.collect_time) });
  }
  return out.sort((a, b) => b.collectedAt - a.collectedAt);
}

/** 账号资料（官方「我的」顶部）：头像、昵称、红果号、签名、会员、累计观看时长、活跃天数 */
async function profile({ cookie, signal } = {}) {
  if (!cookie) throw fail('未登录', 'NOT_SIGNED_IN');
  const d = checkAccount(await accountGet(cookie, '/reading/user/info/v1/', {}, signal), '读取账号资料');
  const uid = String(d.biz_user_id || d.user_id || '').trim();
  if (!uid) throw fail('登录已失效，请重新登录', 'SESSION_EXPIRED');
  const vip = d.vip_info || {};
  const num = v => Math.max(0, Number(v) || 0);
  return { uid, name: cleanTitle(d.user_name) || '红果用户', avatar: avatarUrl(d.expand_avatar_url || d.avatar_url || '') || String(d.expand_avatar_url || d.avatar_url || ''),
    cover: String(d.profile_cover_url || ''), signature: cleanTitle(d.description), vip: String(vip.is_vip) === '1',
    watchMinutes: Math.round(num(d.video_consume_duration) / 60000), activeDays: num(d.active_day),
    follows: num(d.follow_count ?? d.following_count), fans: num(d.fans_count ?? d.follower_count), likes: num(d.digg_count ?? d.total_favorited) };
}

/** 预约（已上线 + 待上线） */
async function reservations({ cookie, signal } = {}) {
  if (!cookie) throw fail('未登录', 'NOT_SIGNED_IN');
  const out = [];
  for (const online of [true, false]) {
    const j = await accountGet(cookie, '/reading/user/subscribe/list/v1/', { offset: '0', limit: '50', is_online: String(online), tab_type: '13',
      session_id: '', subscribe_order_type: '0', swipe_type: '0', need_calendar_schema: 'false', subscribe_offset: '0' }, signal).catch(() => null);
    if (!j || Number(j.code) !== 0) continue;
    for (const row of j.data?.subscribe_items || []) {
      const sd = row?.subscribe_data || {};
      const on = typeof row?.is_online === 'boolean' ? row.is_online : online;
      const id = idOf(on ? (sd.series_id || row.item_id) : (row.item_id || sd.series_id));
      if (!id) continue;
      let t = Number(row.expected_publish_time || row.schedule_publish_time) || 0;
      if (t > 0 && t < 1e10) t *= 1000;
      out.push({ series_id: id, series_title: cleanTitle(sd.title || row.name || row.title) || `剧集 ${id}`,
        cover: catalogCover(sd.cover || row.cover || ''), episode_count: Number(sd.episode_cnt) || 0, upcoming: !on,
        heat: on ? undefined : (t ? `${new Date(t + 8 * 3600e3).getUTCMonth() + 1}月${new Date(t + 8 * 3600e3).getUTCDate()}日上线` : '待上线') });
    }
  }
  return out;
}

/** 登录保活：官网账号接口，服务端在需要时回写新的 sessionid / sid_guard；回合并后的 cookie。登录失效回 expired */
async function keepAlive({ cookie } = {}) {
  if (!cookie) return { expired: true };
  const axios = require('axios');
  const r = await axios({ url: 'https://hongguoduanju.com/passport/account/info/v2/?aid=513755&account_sdk_source=web', method: 'GET',
    headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
      Referer: 'https://hongguoduanju.com/', Origin: 'https://hongguoduanju.com', Accept: 'application/json', Cookie: cookie },
    timeout: 10000, maxRedirects: 0, responseType: 'json', validateStatus: () => true });
  const body = r?.data || {};
  // 会话过期：HTTP 200 + data.error_code 13「会话过期，请重新登录」；只有明确过期才登出，网络抖动不动
  const d = body.data || {};
  if (r.status === 401 || r.status === 403 || Number(d.error_code) === 13 || /会话过期|session_expired/i.test(String(d.description || '') + String(body.message || ''))) return { expired: true };
  if (!String(d.user_id_str || d.user_id || '').match(/[1-9]/)) return { cookie };
  const jar = new Map(String(cookie).split(';').map(p => p.trim()).filter(p => p.includes('=')).map(p => [p.slice(0, p.indexOf('=')), p.slice(p.indexOf('=') + 1)]));
  const set = r?.headers?.['set-cookie'];
  for (const line of Array.isArray(set) ? set : set ? [set] : []) {
    const pair = String(line).split(';', 1)[0], at = pair.indexOf('=');
    if (at > 0) jar.set(pair.slice(0, at).trim(), pair.slice(at + 1).trim());
  }
  return { cookie: [...jar].map(([k, v]) => `${k}=${v}`).join('; ') };
}

// ── 发评论 / 发弹幕（要登录）─────────────────────────────────────────────
// 接口与请求体照 ch6vip/novel-sound（GPL-3.0）rust/src/endpoints/comments.rs：反编译番茄 APK 里的短剧模块
// （AddCommentRequest / playlet/editor/p0.java / hy1/l.java）。红果同一套 fqnovel 后端，aid 换成 8662。
//   剧评：group_id=剧 id、group_type=1(Book)、data_type=2、commit_source=12(NovelPlayletCommentAdd)、带 vid
//   弹幕：group_id=vid、group_type=30(SeriesVideo)、data_type=20、commit_source=1500、business_param.offset 毫秒
const COMMENT_ADD = '/novel/commentapi/comment/add/v1/';
const { signRaw } = require('./upstream/app-source.js');
const WRITE_UA = 'com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; 23127PN0CC; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)';

/** 带登录 cookie + 设备签名的 POST JSON，原样回 { status, json } */
async function signedPostRaw(cookie, apiPath, payload, signal, aid = '8662', extraHeaders = {}) {
  const axios = require('axios');
  const id = loginIdentity || await getPlaybackDevice(requestJson, { signal });
  const { __tag, ...clean } = payload;
  const body = Buffer.from(JSON.stringify(clean));
  const values = { ac: 'wifi', aid, app_name: 'novelread', channel: 'update_64', device_brand: 'Redmi', device_id: id.device_id,
    device_platform: 'android', device_type: '25053RT47C', dpi: '520', iid: id.iid, language: 'zh', manifest_version_code: '73532',
    os: 'android', os_api: '36', os_version: '16', resolution: '1280*2772', ssmix: 'a', update_version_code: '73532',
    version_code: '73532', version_name: '7.3.5.32', cdid: id.cdid, compliance_status: '0' };
  const khronos = Math.floor(Date.now() / 1000), base = Date.now();
  let raw, url, ticket;
  for (let n = 0; n < 128; n++) {
    ticket = base + n;
    raw = signRaw.pythonUrlEncode({ ...values, ts: String(khronos), _rticket: String(ticket) });
    url = `https://api5-normal-sinfonlineb.fqnovel.com${apiPath}?${raw}`;
    // 绿果 lvguoplay/account_signed.go：写接口用分支 2 的完整签名，「旧手写签名在写接口上会被服务端静默丢弃（返回成功但不落库）」
    if (signRaw.branchOf(url, body, khronos) === 2) break;
    if (n === 127) throw fail('请求签名失败', 'SIGN');
  }
  const headers = {
    'User-Agent': WRITE_UA, 'Passport-Sdk-Version': '50561',
    'X-Reading-Request': `${base}-${Math.floor(Math.random() * 0x7fffffff)}`, Accept: 'application/json', 'X-XS-From-Web': '0', 'Sdk-Version': '2', 'X-SS-DP': '8662',
    'X-Tt-Store-Region': 'cn', 'X-Tt-Store-Region-Src': 'did', 'Content-Type': 'application/json; charset=utf-8',
    'X-Khronos': String(khronos), 'X-SS-Req-Ticket': String(ticket), 'X-Helios': signRaw.helios(khronos),
    'X-Medusa': signRaw.buildMedusa(url, body, khronos, { device_id: id.device_id, version_name: '7.3.5.32' }),
    'X-Gorgon': signRaw.xGorgon(raw, body, khronos, Math.floor(Math.random() * 65536)), 'X-SS-STUB': signRaw.md5(body),
    ...(cookie ? { Cookie: cookie } : {}), ...extraHeaders,
  };
  const r = await axios({ url, method: 'POST', data: body, headers, timeout: 15000, maxRedirects: 0, responseType: 'text',
    transformResponse: [d => d], validateStatus: () => true, signal }).catch(() => { throw fail('网络连接失败，请稍后重试', 'NETWORK'); });
  let j = null; try { j = JSON.parse(r.data); } catch (_) {}
  return { status: r.status, json: j };
}

async function signedPost(cookie, apiPath, payload, signal, aid = '8662') {
  const { status, json: j } = await signedPostRaw(cookie, apiPath, payload, signal, aid);
  if (status !== 200 || !j) throw fail(`红果没有接收（HTTP ${status}）`, 'HTTP');
  const code = Number(j.code ?? j.Code ?? 0), msg = String(j.message || j.prompts || j.data?.prompts || '');
  // 只记返回码 / 提示，不记 cookie、正文
  Native.log?.(`comment/add ${payload.__tag || ''} aid=${aid} code=${code} msg=${msg.slice(0, 60)} id=${j.data?.comment_info?.comment_id || j.data?.comment_id || ''}`);
  if (code === 100004 || /session_expired/i.test(msg)) throw fail('登录已失效，请重新登录', 'SESSION_EXPIRED');
  // 有评论 id 就算发出去了
  if (j.data?.comment_info?.comment_id || j.data?.comment_id) return j.data;
  if (code !== 0) throw Object.assign(fail(msg && !/^success$/i.test(msg) ? `发送失败：${msg}（${code}）` : `发送失败（${code}）`, 'APP_BUSINESS'), { upstreamCode: code });
  return j.data || {};
}

/** 发完回读：带登录 cookie 拉这一集评论并要求置顶刚发的那条；能读到 = 真落库了。回 true / false */
async function verifyComment({ cookie, sid, vid, commentId, signal }) {
  await new Promise(r => setTimeout(r, 1200));
  const { status, json: j } = await signedPostRaw(cookie, `/novel/commentapi/comment/list/${vid}/v1/`, {
    business_param: { book_id: sid, need_count: true, req_type: 0, sort: 'video_innerflow', insert_comment_ids: [commentId] },
    comment_source: 4, comment_type: 4, count: 10, group_id: vid, group_type: 30, server_channel: 18, sort: 1, aid: 8662, compliance_status: 0 }, signal);
  const list = j?.data?.data_list || [];
  Native.log?.(`comment/verify status=${status} code=${j?.code} n=${list.length}`);
  return list.some(e => String(e?.comment?.comment_id) === commentId);
}

/** 发评论：挂在整部剧上（官方短剧评论编辑器同款），带上当前集 vid */
async function addComment({ cookie, sid, vid, text, signal } = {}) {
  if (!cookie) throw fail('登录后才能发评论', 'NOT_SIGNED_IN');
  const t = String(text || '').trim();
  if (!t) throw fail('写点什么再发', 'APP_INPUT');
  if (t.length > 500) throw fail('评论最多 500 字', 'APP_INPUT');
  const id = idOf(sid), v = idOf(vid);
  if (!id) throw fail('剧集编号无效', 'APP_INPUT');
  // 红果 7.4.5.32 反编译实证（kmp_video_comment/publish/VideoCommentContentPublishRepo + CommentContentPublishRepo）：
  //   单集评论 commit_source=NovelItemCommentAdd(3)、group_id=vid、group_type=SeriesVideo(30)、data_type=NewItem(4)、
  //   business_param.book_id=剧 id；aid 取 App 的 appId（拿不到时官方兜底 1967）→ 先 8662 再 1967，只在 103001 时换
  const body = { business_param: { book_id: id }, commit_source: 3, data_type: 4, group_id: v || id, group_type: 30, text: t };
  let last;
  for (const aid of ['8662', '1967']) {
    try {
      const d = await signedPost(cookie, COMMENT_ADD, { ...body, __tag: 'item' }, signal, aid);
      const commentId = String(d.comment_info?.comment_id || d.comment_id || '');
      const status = d.comment_info?.common?.status;
      const verified = v && commentId ? await verifyComment({ cookie, sid: id, vid: v, commentId, signal }).catch(() => null) : null;
      Native.log?.(`comment/add verify status=${status ?? ''} found=${verified}`);
      return { ok: true, commentId, status: status ?? null, verified, via: 'item-' + aid };
    } catch (e) { last = e; if (e.upstreamCode !== 103001) throw e; }
  }
  throw last;
}

/** 发弹幕：挂在这一集的这个时间点上 */
async function addDanmaku({ cookie, sid, vid, text, offsetMs, signal } = {}) {
  if (!cookie) throw fail('登录后才能发弹幕', 'NOT_SIGNED_IN');
  const t = String(text || '').trim();
  if (!t) throw fail('写点什么再发', 'APP_INPUT');
  if (t.length > 100) throw fail('弹幕最多 100 字', 'APP_INPUT');
  const id = idOf(sid), v = idOf(vid);
  if (!id || !v) throw fail('剧集编号无效', 'APP_INPUT');
  // 反编译实证（kmp_video_danmaku/publish/data/VideoDanmakuPublishRepo）：commit_source=NovelItemDanmakuAdd(1500)、group_type=30、
  // data_type=Danmaku(20)、business_param.offset=毫秒、shark_param={type:short_play, aid}
  let last;
  for (const aid of ['8662', '1967']) {
    try {
      const d = await signedPost(cookie, COMMENT_ADD, { business_param: { book_id: id, offset: Math.max(1, Math.round(Number(offsetMs) || 0)),
        shark_param: { type: 'short_play', aid } }, commit_source: 1500, data_type: 20, group_id: v, group_type: 30, text: t, __tag: 'danmaku' }, signal, aid);
      return { ok: true, commentId: String(d.comment_info?.comment_id || d.comment_id || '') };
    } catch (e) { last = e; if (e.upstreamCode !== 103001) throw e; }
  }
  throw last;
}

// ---------- 手机扫电视登录码 ----------
// 电视 GuoDuo TV 的登录码是红果官网扫码登录（hongguoduanju.com get_qrcode，二维码内容 = reading.snssdk.com/…/scan-code.html?token=…&qr_source_aid=513755）。
// 红果 App 扫到后做两步（APK dh1/c + 页面 scan-code.js 6747 模块）：
//   1. GET  /passport/mobile/scan_qrcode/?aid=8662&token=   → 电视那边变「已扫码」，返回来源（网页名）和 confirmed_url（带 csrf_token/csrf_ts）
//   2. POST /passport/mobile/confirm_qrcode/?…  {aid, token, decision:0, csrf_token, csrf_ts} → 电视那边「已确认」，拿到它自己的新会话
// 只带本机登录 cookie 发给红果，cookie 不经过电视、不进日志。
const PASSPORT = 'https://api5-normal-sinfonlineb.fqnovel.com';
function parseLoginQR(text) {
  let u; try { u = new URL(String(text || '').trim()); } catch (_) { return null; }
  if (!/(^|\.)snssdk\.com$|(^|\.)hongguoduanju\.com$|(^|\.)fqnovel\.com$/i.test(u.hostname)) return null;
  const token = u.searchParams.get('token') || '';
  if (!/^[A-Za-z0-9_\-]{8,80}$/.test(token)) return null;
  return { token, sourceAid: u.searchParams.get('qr_source_aid') || '' };
}
async function passportCall(cookie, path, query, body, signal) {
  const axios = require('axios');
  const id = loginIdentity || await getPlaybackDevice(requestJson, { signal });
  const q = new URLSearchParams({ aid: '8662', device_id: id.device_id || '', iid: id.iid || '', device_platform: 'android', app_name: 'novelread', ...query });
  const r = await axios({ url: `${PASSPORT}${path}?${q}`, method: body ? 'POST' : 'GET', data: body ? new URLSearchParams(body).toString() : undefined,
    headers: { 'User-Agent': WRITE_UA, Cookie: cookie, 'Passport-Sdk-Version': '50561', 'X-SS-DP': '8662', Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
    timeout: 12000, responseType: 'text', transformResponse: [d => d], validateStatus: () => true, signal })
    .catch(() => { throw fail('网络连接失败，请稍后重试', 'NETWORK'); });
  let j = null; try { j = JSON.parse(r.data); } catch (_) {}
  if (!j) throw fail(`红果没有返回（HTTP ${r.status}）`, 'HTTP');
  const d = j.data || {};
  Native.log?.(`tvlogin ${path.split('/')[3]} msg=${j.message} code=${d.error_code ?? ''}`);
  if (j.message !== 'success') {
    const desc = String(d.description || '');
    if (d.error_code === 1071 || /过期/.test(desc)) throw fail('二维码已过期，请在电视上刷新后重扫', 'EXPIRED');
    if (d.error_code === 1073 || /未登录/.test(desc)) throw fail('手机还没登录红果账号（我的 → 登录）', 'NOT_LOGGED_IN');
    throw fail(desc || '红果拒绝了这次登录', 'PASSPORT');
  }
  return d;
}
/** 第 1 步：扫码（电视上会显示「已扫码，请在手机确认」） */
async function tvLoginScan({ cookie, text, signal }) {
  if (!cookie) throw fail('手机还没登录红果账号（我的 → 登录）', 'NOT_LOGGED_IN');
  const qr = parseLoginQR(text);
  if (!qr) throw fail('这不是红果登录二维码', 'NOT_LOGIN_QR');
  const d = await passportCall(cookie, '/passport/mobile/scan_qrcode/', { token: qr.token }, null, signal);
  let csrf = {};
  try { const cu = new URL(String(d.confirmed_url || ''), 'https://x/'); csrf = { csrf_token: cu.searchParams.get('csrf_token') || '', csrf_ts: cu.searchParams.get('csrf_ts') || '' }; } catch (_) {}
  const src = d.source || {};
  return { token: qr.token, title: String(src.title || d.app_name || d.web_name || '网页'), desc: String(src.des || ''), ...csrf };
}
/** 第 2 步：确认登录（decision 0 = 同意） */
async function tvLoginConfirm({ cookie, token, csrf_token, csrf_ts, signal }) {
  if (!cookie) throw fail('手机还没登录红果账号（我的 → 登录）', 'NOT_LOGGED_IN');
  const body = { aid: '8662', token, decision: '0', csrf_token: csrf_token || '', csrf_ts: csrf_ts || '' };
  await passportCall(cookie, '/passport/mobile/confirm_qrcode/', body, body, signal);
  return { ok: true };
}

module.exports = { forYou, historyAll, favorites, collectDramas, keepAlive, profile, reservations, useIdentity, addComment, addDanmaku, tvLoginScan, tvLoginConfirm, parseLoginQR };
