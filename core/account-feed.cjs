// GuoDuo 自有（不是上游拷贝，同步上游不会覆盖）：登录红果账号后的「为你推荐」流、完整观看记录、云端收藏。
// 参考绿果TV 2.0.8（Amor5207/lvguo-tv，GPL-3.0）src/ink/pengfei/lvguo/net/Browse.java forYou / Account.java history、favorites。
// 登录态 cookie 来自上游 account-session.js 扫码登录（存在钥匙串 hg.account.session）。
const { signedMetadataRequest, signedAccountRequest, requestJson } = require('./upstream/app-source.js');
const { getPlaybackDevice } = require('./upstream/playback-device.js');
const { catalogCover } = require('./upstream/hongguo-app-catalog.js');
const { cleanTitle } = require('./upstream/hongguo-app-search.js');
const { meta } = require('./catalog-more.cjs');

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
  if (code === 100004 || /session_expired/i.test(msg) || /session_expired/i.test(name)) throw fail('登录已失效，请重新扫码登录', 'SESSION_EXPIRED');
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
const CHANNELS = ['16', '36', '39'];
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

async function accountGet(cookie, apiPath, values, signal) {
  const identity = await getPlaybackDevice(requestJson, { signal });
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

module.exports = { forYou, historyAll, favorites, collectDramas };
