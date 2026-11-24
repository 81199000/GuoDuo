// GuoDuo 自有（不是上游拷贝，同步上游不会覆盖）：登录红果账号后的「为你推荐」流、完整观看记录、云端收藏。
// 参考绿果TV 2.0.8（Amor5207/lvguo-tv，GPL-3.0）src/ink/pengfei/lvguo/net/Browse.java forYou / Account.java history、favorites。
// 登录态 cookie 来自上游 account-session.js 扫码登录（存在钥匙串 hg.account.session）。
const { signedMetadataRequest, signedAccountRequest, requestJson } = require('./upstream/app-source.js');
const { getPlaybackDevice } = require('./upstream/playback-device.js');
const { catalogCover } = require('./upstream/hongguo-app-catalog.js');
const { cleanTitle } = require('./upstream/hongguo-app-search.js');

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

/** 推荐流里所有剧（递归找 series_id + 标题；只留短剧，去掉切片 / 运营位） */
function collectDramas(value, out, seen, depth = 0) {
  if (depth > 10 || !value || typeof value !== 'object') return;
  if (Array.isArray(value)) { for (const v of value) collectDramas(v, out, seen, depth + 1); return; }
  const id = idOf(value.series_id_str || value.series_id);
  const title = cleanTitle(value.series_title || value.series_name || value.title);
  const episodes = Number(value.episode_cnt) || 0;
  if (id && title && !seen.has(id) && DRAMA_TYPES.includes(Number(value.content_type)) && episodes > 0) {
    const cover = catalogCover(value.cover || value.series_cover || '');
    if (cover) {
      seen.add(id);
      const tags = Array.isArray(value.sub_title_list) ? value.sub_title_list.map(t => cleanTitle(t?.content)).filter(Boolean).slice(0, 4) : [];
      out.push({ series_id: id, series_title: title, cover, episode_count: episodes,
        description: cleanTitle(value.video_desc || value.series_intro), tags });
    }
  }
  for (const k of Object.keys(value)) if (value[k] && typeof value[k] === 'object') collectDramas(value[k], out, seen, depth + 1);
}

/**
 * 红果首页「推荐」流：带登录 cookie = 账号个性化推荐；每次请求内容都会变。
 * offset / session 用上一页返回的 next / session 续页。
 */
async function forYou({ cookie = '', offset = 0, session = '', signal } = {}) {
  const values = { bottom_tab_type: '7', client_req_type: '2', client_template: '7', change_type: '0', category_id: '0',
    cell_sub_id: '0', limit: '0', need_personal_recommend: '1', video_type_preferences_str: '[]',
    cell_id: FEED_CELL, plan_id: FEED_PLAN, tab_type: '16', offset: String(Math.max(0, Number(offset) || 0)),
    session_id: String(session || ''), filter_ids: '' };
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
