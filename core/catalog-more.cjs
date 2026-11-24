// GuoDuo 自有（不是上游拷贝，同步上游不会覆盖）：红果 App 官方榜单全集 + 「找剧」筛选（分类落地页）。
// 接口与上游 hongguo-app-catalog.js 相同（bookmall/cell/change 榜单、distribution/category/landpage 分类），
// 这里放开上游写死的 4 个榜单 / 只按题材筛：所有榜单 ID 和筛选项都由服务端下发（2026-11-24 实测）。
const { signedMetadataRequest, requestJson } = require('./upstream/app-source.js');
const { catalogCover } = require('./upstream/hongguo-app-catalog.js');
const { cleanTitle } = require('./upstream/hongguo-app-search.js');

const RANK_API = '/reading/bookapi/bookmall/cell/change/v';
const FIND_API = '/reading/distribution/category/landpage/v/';
const RANK_CELL = '7470092475068071998';
const IDS = ['series_id', 'vid', 'cell_id', 'plan_id', 'book_id', 'related_album_id'];
const fail = (message, code) => Object.assign(new Error(message), { code });
const idOf = v => { const s = String(v ?? '').trim(); return /^\d{1,30}$/.test(s) && /[1-9]/.test(s) ? s : ''; };
const SAFE_ITEM = /^[a-z0-9_]{1,48}$/i;

async function call(path, values, body, signal) {
  let last;
  for (let t = 0; t < 2; t++) {
    try {
      const s = signedMetadataRequest(path, values, body);
      return await requestJson(s.url, { method: body ? 'POST' : 'GET', headers: s.headers, data: s.body, preserveLargeIntegerFields: IDS },
        Date.now() + 10000, signal);
    } catch (e) { last = e; if (signal?.aborted) break; await new Promise(r => setTimeout(r, 500)); }
  }
  throw last;
}

const jsonOf = v => { if (v && typeof v === 'object') return v; try { return JSON.parse(v || 'null'); } catch (_) { return null; } };
const SEASON = /^第.{1,4}[季部]$/;

/**
 * 卡片角标和标签（官方卡片同款）：热度 / 在追 / 期待人数 + 3 个题材标签。
 * 来源：rec_text_item（榜单「8209万热度」「3805万期待」）、rec_tags（推荐流「5426万热度」「共62万人在追」）、
 * recommend_reason_list 里 data_type 27 的热度值（找剧「6256万」）、data_type 3 的题材；都没有就用 category_schema。
 */
function meta(v) {
  const reason = jsonOf(v?.recommend_reason_list) || {};
  const lists = [reason.secondary_info_list, reason.sub_title_list, v?.secondary_infos, v?.secondary_info_list, v?.sub_title_list]
    .filter(Array.isArray).flat();
  let heat = cleanTitle(v?.rec_text_item?.RecommendText);
  if (!heat) heat = cleanTitle((Array.isArray(reason.rec_tags) ? reason.rec_tags : Array.isArray(v?.rec_tags) ? v.rec_tags : [])
    .map(t => t?.content).find(t => /热度|在追|期待|推荐/.test(t || '')));
  if (!heat) { const h = lists.find(t => Number(t?.data_type) === 27)?.content; if (h) heat = `${cleanTitle(h)}热度`; }
  // data_type 3 = 题材（23 演员、32 类型）；不够 3 个用 category_schema 补
  let tags = lists.filter(t => Number(t?.data_type) === 3).map(t => cleanTitle(t?.content));
  tags = tags.concat((jsonOf(v?.category_schema) || []).map(c => cleanTitle(c?.name)));
  tags = [...new Set(tags.filter(t => t && t.length <= 6 && !SEASON.test(t)))].slice(0, 3);
  const badge = cleanTitle(reason.tag_info?.text || v?.video_tag_info?.text);
  return { heat: heat || undefined, tags, badge: badge || undefined };
}

function card(v, extra = {}, { upcoming = false } = {}) {
  const id = idOf(v?.series_id_str || v?.series_id), title = cleanTitle(v?.title || v?.series_title || v?.series_name);
  const episodes = Number(v?.episode_cnt) || 0;
  const type = Number(v?.content_type);
  // 1 真人剧 / 1004 短剧；1007 = 预约中（还没上线，不能播）
  if (!id || !title || !([1, 1004].includes(type) || (upcoming && type === 1007))) return null;
  const plays = Number(v.series_play_cnt || v.play_cnt) || 0;
  return { series_id: id, series_title: title, cover: catalogCover(v.cover || v.series_cover || ''), episode_count: episodes,
    description: cleanTitle(v.video_desc || v.series_intro), plays, ...meta(v), ...(type === 1007 ? { upcoming: true } : {}), ...extra };
}

/** 榜单目录：分区（全部 / 系列剧 / 漫剧 / 真人剧 / AI 剧）→ 各自的榜（推荐 / 热播 / 新剧 / 热搜 / 必看…），服务端下发 */
function parseBoards(selector) {
  return (selector?.outer_row?.items || []).flatMap(o => {
    const id = String(o?.selector_item_id || ''), name = cleanTitle(o?.show_name);
    if (!SAFE_ITEM.test(id) || !name) return [];
    const boards = (o.sub_cell_selector?.outer_row?.items || []).flatMap(b => {
      const bid = String(b?.selector_item_id || ''), bname = cleanTitle(b?.show_name);
      return SAFE_ITEM.test(bid) && bname ? [{ id: bid, name: bname }] : [];
    });
    return boards.length ? [{ id, name, boards }] : [];
  });
}

/** 一页榜单。page 1 用 tab_type 26（同时下发榜单目录），续页用 18 + 上一页的 offset / session */
async function rank({ zone = 'all', board = 'ranklist_hot_play_sc', offset = 0, session = '', signal } = {}) {
  if (!SAFE_ITEM.test(zone) || !SAFE_ITEM.test(board)) throw fail('榜单无效', 'APP_INPUT');
  offset = Math.max(0, Number(offset) || 0);
  const values = { tab_type: offset ? '18' : '26', client_req_type: '2', client_template: '2', background_selected_items: '',
    category_id: '0', limit: '20', cell_sub_id: '0', gender: '2', cell_id: RANK_CELL, selected_items: zone,
    sub_selected_items: board, panel_selected_items: '', offset: String(offset), session_id: String(session || ''),
    filter_ids: '', unlimited_selector_change_type: '0' };
  const j = await call(RANK_API, values, null, signal);
  const view = j?.data?.cell_view;
  if (Number(j?.code) !== 0 || !Array.isArray(view?.cell_data)) throw fail('榜单暂时打不开', 'APP_BUSINESS');
  const rows = view.cell_data.flatMap(c => Array.isArray(c?.video_data) ? c.video_data : c?.video_data ? [c.video_data] : []);
  const seen = new Set(), results = [];
  const upcoming = /subscribe/.test(board);
  for (const v of rows) {
    const c = card(v, { rank: offset + results.length + 1 }, { upcoming });
    if (c && !seen.has(c.series_id)) { seen.add(c.series_id); results.push(c); }
  }
  const next = Number(view.next_offset) || 0;
  return { results, next, session: String(view.session_id || session || ''), hasMore: view.has_more === true && next > offset,
    zones: offset ? [] : parseBoards(view.cell_selector) };
}

/** 「找剧」筛选项（类型 / 排序 / 上新时间 / 题材 / 人设 / 时代 / 男女频），服务端下发 */
function parseFilters(rows) {
  const names = { genre: '类型', sort: '排序', online_time: '上新', gender: '频道', category_dim_theme: '题材',
    category_dim_role: '人设', category_dim_epoch: '背景', creation_status: '状态' };
  return (Array.isArray(rows) ? rows : []).flatMap(r => {
    const type = String(r?.type || '');
    if (!Object.hasOwn(names, type)) return [];
    const items = (r.items || []).flatMap(i => {
      const id = String(i?.selector_item_id ?? ''), name = cleanTitle(i?.show_name);
      return /^[a-z0-9_]{1,48}$/i.test(id) && name ? [{ id, name }] : [];
    });
    return items.length ? [{ type, name: cleanTitle(r.title || r.show_name) || names[type], items }] : [];
  });
}

const FIND_KEYS = ['genre', 'sort', 'category_dim_theme', 'category_dim_role', 'category_dim_epoch', 'gender', 'online_time', 'creation_status'];

/** 一页「找剧」：select = { genre: 'short_play', sort: 'online_time', online_time: 'days_7', category_dim_theme: 'cate_5000', … }（单选） */
async function find({ select = {}, offset = 0, session = '', signal } = {}) {
  offset = Math.max(0, Number(offset) || 0);
  const items = {};
  for (const k of FIND_KEYS) {
    const v = String(select?.[k] ?? '');
    items[k] = v && /^[a-z0-9_]{1,48}$/i.test(v) ? [v] : [];
  }
  if (!items.genre.length) items.genre = ['short_play'];
  if (!items.sort.length) items.sort = ['hot_score'];
  const first = offset === 0;
  const body = { filter_ids: '', req_scene: items.genre[0] === 'short_play' ? 'default' : items.genre[0], offset, need_selector_panel: first,
    limit: 18, select_items: items, session_id: String(session || ''), req_type: first ? 'default' : 'only_content', client_req_type: 3 };
  const j = await call(FIND_API, {}, body, signal);
  const data = j?.data;
  if (Number(j?.code) !== 0 || !Array.isArray(data?.video_data)) throw fail('找剧暂时打不开', 'APP_BUSINESS');
  const seen = new Set(), results = [];
  for (const v of data.video_data) { const c = card(v); if (c && !seen.has(c.series_id)) { seen.add(c.series_id); results.push(c); } }
  const next = Number(data.next_offset) || 0;
  return { results, next, session: String(data.session_id || session || ''), hasMore: data.has_more === true && next > offset,
    filters: first ? parseFilters(data.selector_rows) : [] };
}

module.exports = { rank, find, parseBoards, parseFilters, meta };
