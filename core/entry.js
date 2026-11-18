import { Buffer } from 'buffer/';
import { browseList } from './upstream/hongguo-app-catalog.js';
import { searchApp } from './upstream/hongguo-app-search.js';
import { fetchAppPlayUrl } from './upstream/app-source.js';
import { website, parseDetail } from './upstream/public.js';
import { fetchDanmaku, setDeviceIdentityFile } from './upstream/danmaku.js';
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
  browse(callId, category, page) { wrap(callId, async () => {
    if (category === 'xifan' || category === 'hema') return unwrap(await (category === 'xifan' ? xifan : hema).browseList({ page }));
    return unwrap(await browseList({ category, page }));
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
  danmaku(callId, sid, vid) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const r = await fetchDanmaku({ seriesId: String(sid), vid: String(vid), signal: controller.signal });
        if (!r.success) throw Object.assign(new Error(r.notice || r.error || '弹幕源不可用'), { code: 'DANMAKU_UNAVAILABLE' });
        return { items: r.items.map(i => ({ time: i.time, text: i.text, color: i.color, mode: i.mode })) };
      } finally { controllers.delete(callId); }
    });
  },
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
