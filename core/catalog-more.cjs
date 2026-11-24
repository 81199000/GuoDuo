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

// ---------------------------------------------------------------- 搜索联想 / 剧集补充信息 / 选季 / 剧评

const V722 = { version_code: '72232', version_name: '7.2.2.32', manifest_version_code: '72232', update_version_code: '72232', pv_player: '72232' };

/** 搜索联想：输入「重生」→ 剧名候选（同官方搜索框下拉） */
async function suggest({ query = '', signal } = {}) {
  query = String(query || '').trim().slice(0, 40);
  if (!query) return { results: [] };
  const j = await call('/reading/bookapi/search/suggest/v1/', { ...V722, query, q: query, count: '0', tab_type: '11',
    bookshelf_search_plan: '4', search_source: '0', bookstore_tab: '0', user_is_login: '0' }, null, signal);
  if (Number(j?.code) !== 0) throw fail('联想暂时不可用', 'APP_BUSINESS');
  const out = [], seen = new Set();
  (function walk(v, d) {
    if (d > 8 || !v || typeof v !== 'object' || out.length >= 10) return;
    if (Array.isArray(v)) { v.forEach(x => walk(x, d + 1)); return; }
    const text = cleanTitle(v.title || v.text || v.query || v.word);
    if (text && text.length <= 40 && !seen.has(text) && (v.title || v.text)) { seen.add(text); out.push(text); }
    for (const k of Object.keys(v)) if (v[k] && typeof v[k] === 'object') walk(v[k], d + 1);
  })(j.data?.suggest_result || j.data, 0);
  return { results: out };
}

const DETAIL_API = '/novel/player/video_detail/v1/';
async function detailRaw(sid, signal) {
  const id = idOf(sid);
  if (!id) throw fail('剧集编号无效', 'APP_INPUT');
  const j = await call(DETAIL_API, {}, { biz_param: { source: 5, video_id_type: 1 }, series_id: id, video_id: id }, signal);
  if (Number(j?.code) !== 0 || !j?.data?.video_data) throw fail(Number(j?.code) === 101001 ? '该剧已下架' : '详情暂时打不开', 'APP_BUSINESS');
  return j.data.video_data;
}

/** 详情补充：播放 / 在追 / 热度、新剧·爆剧角标、题材、演员、第几季、完结状态 */
async function info({ sid, signal } = {}) {
  const v = await detailRaw(sid, signal);
  const sec = Array.isArray(v.secondary_infos) ? v.secondary_infos : [];
  const tags = [...new Set(sec.filter(t => Number(t?.data_type) === 3).map(t => cleanTitle(t.content))
    .concat((jsonOf(v.category_schema) || []).map(c => cleanTitle(c?.name))).filter(Boolean))].slice(0, 6);
  const actors = cleanTitle(sec.find(t => Number(t?.data_type) === 33)?.content || '').replace(/^演员·/, '');
  return { series_id: idOf(v.series_id_str || v.series_id), plays: Number(v.series_play_cnt) || 0, followers: Number(v.followed_cnt) || 0,
    heat: Number(v.hot_score) || 0, badge: cleanTitle(v.video_tag_info?.text) || undefined, tags, actors: actors || undefined,
    season: Number(v.season_index) || 0, episodes: Number(v.episode_cnt) || 0, status: cleanTitle(v.episode_right_text) || undefined,
    album: idOf(v.related_album_id) || undefined };
}

/** 系列剧选季：同一系列的各季（去掉已下架的）；不是系列剧回空 */
async function seasons({ sid, album = '', signal } = {}) {
  let albumId = idOf(album);
  if (!albumId) albumId = idOf((await detailRaw(sid, signal)).related_album_id);
  if (!albumId) return { results: [] };
  const j = await call('/api/novel/origin/album/get_video_list/v1/', { album_id: albumId, offset: '0', limit: '50' }, null, signal);
  const list = Array.isArray(j?.data?.video_data_list) ? j.data.video_data_list : [];
  const ids = [...new Set(list.map(x => idOf(x?.video_id)).filter(Boolean))];
  // 列表里混着已下架的旧版本：逐个查详情，能打开的才算一季（同一季多条只留播放多的）
  const rows = (await Promise.all(ids.map(id => detailRaw(id, signal).then(v => v, () => null)))).filter(Boolean);
  const bySeason = new Map();
  for (const v of rows) {
    const n = Number(v.season_index) || 1;
    const prev = bySeason.get(n);
    if (!prev || (Number(v.series_play_cnt) || 0) > (Number(prev.series_play_cnt) || 0)) bySeason.set(n, v);
  }
  const results = [...bySeason.entries()].sort((a, b) => a[0] - b[0]).map(([n, v]) => ({
    season: n, series_id: idOf(v.series_id_str || v.series_id), series_title: cleanTitle(v.series_title),
    cover: catalogCover(v.series_cover || ''), episode_count: Number(v.episode_cnt) || 0 }));
  return { results: results.length > 1 ? results : [], album: cleanTitle(j?.data?.album_data?.album_name) || undefined };
}

/** 整部剧的评论（剧评），带评分；offset 续页 */
async function reviews({ sid, offset = 0, signal } = {}) {
  const id = idOf(sid);
  if (!id) throw fail('剧集编号无效', 'APP_INPUT');
  offset = Math.max(0, Number(offset) || 0);
  const j = await call('/reading/ugc/novel_comment/book/v1/', { book_id: id, offset: String(offset), count: '20', sort: '0', source_type: '32' }, null, signal);
  const d = j?.data;
  if (Number(j?.code) !== 0 || !d) throw fail('剧评暂时打不开', 'APP_BUSINESS');
  const items = (Array.isArray(d.comment) ? d.comment : []).flatMap(c => {
    const text = cleanTitle(c?.text);
    if (!text) return [];
    const ts = Number(c.create_timestamp) || 0;
    return [{ id: String(c.comment_id || `${ts}-${text.slice(0, 8)}`), author: cleanTitle(c.user_info?.user_name) || '红果用户',
      avatar: catalogCover(c.user_info?.user_avatar || '') || undefined, content: text, created_at: ts, likes: Number(c.digg_count) || 0,
      score: Number(c.score) || 0 }];
  });
  const next = Number(d.next_offset) || 0;
  return { items, total: Number(d.comment_cnt) || 0, next, hasMore: d.has_more === true && next > offset };
}

module.exports = { rank, find, parseBoards, parseFilters, meta, suggest, info, seasons, reviews };
