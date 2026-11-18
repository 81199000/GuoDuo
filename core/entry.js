import { Buffer } from 'buffer/';
import { browseList } from './upstream/hongguo-app-catalog.js';
import { searchApp } from './upstream/hongguo-app-search.js';
import { fetchAppPlayUrl, signedMetadataRequest, requestJson } from './upstream/app-source.js';
import { website, parseDetail } from './upstream/public.js';
import { requestWindow, parsePage, toSeconds, cleanControl, setDeviceIdentityFile, MAX_TEXT_LEN } from './upstream/danmaku.js';
import { fetchPublicDetails } from './upstream/public-details.js';
import { createAccountService } from './upstream/account-session.js';
import * as xifan from './upstream/xifan.js';
import * as hema from './upstream/hema.js';

const PLAYABLE = ['h264', 'avc', 'avc1', 'hevc', 'h265', 'hvc1', 'hev1', 'bytevc1'];
const plain = e => ({ message: String(e?.message || e), code: e?.code || '' });
// 每个调用返回 Promise，结果统一回到原生 Native.done(callId, json)。
function wrap(callId, task) {
  Promise.resolve().then(task).then(
    value => Native.done(callId, JSON.stringify({ ok: true, value: value ?? null })),
    error => Native.done(callId, JSON.stringify({ ok: false, error: plain(error) })));
}
const unwrap = r => { if (r && r.success === false) throw Object.assign(new Error(r.error || '加载失败'), { code: r.code || '' }); return r; };
const controllers = new Map();
const sourceOf = id => String(id).startsWith('xifan:') ? xifan : String(id).startsWith('hema:') ? hema : null;

// 弹幕匿名标识需跨重启复用；钥匙串一条。
setDeviceIdentityFile('hg.danmaku.identity');
// 钥匙串本身加密，safeStorage 只做透传。
const safeStorage = { isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'keychain',
  encryptString: s => Buffer.from(s, 'utf8'), decryptString: b => Buffer.from(b).toString('utf8') };
const account = createAccountService({ filePath: 'hg.account.session', safeStorage });

const normEpisodes = d => ({ series_id: String(d.series_id), series_title: String(d.series_title || '未命名短剧'),
  cover: d.cover || '', description: d.description || '',
  episodes: (d.episodes || []).map((e, i) => ({ vid: String(e.vid), number: Number(e.number || e.vid_index) || i + 1, locked: e.locked === true })) });

globalThis.HG = {
  browse(callId, category, page, genre) { wrap(callId, async () => {
    if (category === 'xifan' || category === 'hema') return unwrap(await (category === 'xifan' ? xifan : hema).browseList({ page }));
    return unwrap(await browseList({ category, page, genre: genre || '' }));
  }); },
  // 粘贴红果分享链接/口令里的链接 → 剧集编号。只认 URL 参数与 /player/ 路径，不跟随跳转。
  resolveShare(callId, text) { wrap(callId, async () => {
    const m = String(text || '').match(/https?:\/\/[^\s<>"'，。）)]+/);
    if (!m) throw new Error('没有找到链接');
    let url = new URL(m[0]);
    for (let hop = 0; hop < 4; hop++) {
      const direct = url.searchParams.get('video_series_id') || url.searchParams.get('series_id');
      if (/^\d{1,30}$/.test(direct || '')) return { series_id: direct };
      const player = url.pathname.match(/^\/player\/(\d{1,30})(?:\/|$)/);
      if (player) return { series_id: player[1] };
      const scheme = url.searchParams.get('schemeParams');
      const vid = scheme && decodeURIComponent(scheme).match(/"video_id"\s*:\s*"(\d{1,30})"/);
      if (vid) return { series_id: vid[1] };
      const r = await (await import('./shims/axios.cjs')).default({ url: url.href, maxRedirects: 0, validateStatus: () => true, responseType: 'text', transformResponse: [d => d] });
      if (!r.headers?.location) break;
      url = new URL(r.headers.location, url);
    }
    throw new Error('无法从链接中识别红果剧集');
  }); },
  search(callId, keyword, page, cursor, source) { wrap(callId, async () => {
    if (source === 'xifan' || source === 'hema') return unwrap(await (source === 'xifan' ? xifan : hema).search(keyword, page));
    return searchApp(keyword, { page, cursor: cursor ? JSON.parse(cursor) : null });
  }); },
  episodes(callId, sid) { wrap(callId, async () => {
    const other = sourceOf(sid);
    if (other) return normEpisodes(await other.fetchEpisodeList(String(sid)));
    return normEpisodes(parseDetail(await website(`/player/${sid}`), String(sid)));
  }); },
  // 只返回原生能播的编码；签名和 contentKey 原样透传，不改动。
  source(callId, vid, quality) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const other = sourceOf(vid);
        if (other) {
          const r = await other.fetchPlayUrlSingle(String(vid));
          if (!r.url) throw Object.assign(new Error(r.error || '片源不可用'), { code: r.locked ? 'LOCKED' : '' });
          return { vid: String(vid), variants: [{ url: r.url, contentKey: null, codec: 'h264', quality: '', userAgent: 'Mozilla/5.0', referer: '' }] };
        }
        const s = await fetchAppPlayUrl(String(vid), { quality: quality || 'auto', signal: controller.signal });
        const variants = (s.variants || [s]).filter(v => PLAYABLE.includes(String(v.codec).toLowerCase()))
          .map(v => ({ url: v.url, contentKey: v.contentKey || null, codec: v.codec, quality: v.quality || s.quality || '', userAgent: v.userAgent || s.userAgent || '', referer: v.referer || '' }));
        if (!variants.length) throw Object.assign(new Error('本集只有 ByteVC2 编码，iOS 暂不支持'), { code: 'UNSUPPORTED_CODEC' });
        return { vid: String(vid), variants };
      } finally { controllers.delete(callId); }
    });
  },
  // 分时弹幕按 30 秒窗口取：startMs=0 取第一窗，返回 next 供播放到附近时再取下一窗（DouDuo 同款）。
  danmaku(callId, sid, vid, startMs, durationMs) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const start = Math.max(0, Number(startMs) || 0);
        const duration = Math.max(60000, Math.min(24 * 3600 * 1000, Number(durationMs) || 3600000));
        const payload = await requestWindow({ vid: String(vid), bookId: String(sid), start, duration, signal: controller.signal })
          .catch(e => { throw Object.assign(new Error('弹幕源暂不可用'), { code: 'DANMAKU_UNAVAILABLE', cause: e }); });
        const { items, nextMs, hasMore } = parsePage(payload, String(vid));
        const out = [];
        for (const it of items) {
          const t = toSeconds(it.timeRaw); const text = cleanControl(it.text);
          if (t === null || !text || text.length > MAX_TEXT_LEN) continue;
          out.push({ time: t, text, color: it.color, mode: it.mode });
        }
        const next = nextMs !== null && nextMs > start && hasMore !== false ? nextMs : null;
        return { items: out, next };
      } finally { controllers.delete(callId); }
    });
  },
  // App 剧集详情：每集评论数 / 点赞数，整剧追剧数 / 播放量（官网第 6 集以后不公开，只能走 App 签名接口）。
  stats(callId, sid) { wrap(callId, async () => {
    const body = { series_id: String(sid), biz_param: { caller_scene: 'single_col', detail_page_version: 0, from_video_id: '',
      need_all_video_definition: false, need_mp4_align: false, source: 4, video_id_type: 1 } };
    const s = signedMetadataRequest('/novel/player/video_detail/v1/', {}, body);
    const j = await requestJson(s.url, { method: 'POST', headers: s.headers, data: s.body }, Date.now() + 10000);
    if (!j || Number(j.code) !== 0) throw new Error('剧集统计不可用');
    const vd = j.data?.video_data || {};
    if (String(vd.series_id_str || vd.series_id || sid) !== String(sid)) throw new Error('剧集统计不匹配');
    const n = v => Number.isFinite(Number(v)) ? Number(v) : null;
    return { follows: n(vd.followed_cnt), plays: n(vd.series_play_cnt),
      episodes: (vd.video_list || []).map(e => ({ vid: String(e.vid), comments: n(e.comment_count), likes: n(e.digged_count) })) };
  }); },
  // 官网公开页的本集热评（最多 15 条）+ 本集点赞、本剧收藏数。
  comments(callId, sid, vid) { wrap(callId, async () => {
    const d = unwrap(await fetchPublicDetails(String(sid), String(vid), { reviewsLimit: 15 }));
    return { total: d.episode_reviews?.total ?? null, items: (d.episode_reviews?.items || []).slice(0, 15),
      episodeLikes: d.episode_like_count ?? null, favorites: d.favorite_count ?? null };
  }); },
  accountStatus(callId) { wrap(callId, () => account.status()); },
  accountStartLogin(callId) { wrap(callId, () => account.startLogin()); },
  accountPollLogin(callId, id) { wrap(callId, () => account.pollLogin(id)); },
  accountCancelLogin(callId, id) { wrap(callId, () => account.cancelLogin?.(id)); },
  accountLogout(callId) { wrap(callId, () => account.logout()); },
  accountHistory(callId, refresh) { wrap(callId, () => account.history({ refresh: !!refresh })); },
  cancel(callId) { controllers.get(callId)?.abort(); },
};
globalThis.Buffer = Buffer;
Native.log('HG core ready');
