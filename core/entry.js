import { Buffer } from 'buffer/';
import { browseList } from './upstream/hongguo-app-catalog.js';
import { searchApp } from './upstream/hongguo-app-search.js';
import { fetchAppPlayUrl } from './upstream/app-source.js';
import { website, parseDetail } from './upstream/public.js';

const PLAYABLE = ['h264', 'avc', 'avc1', 'hevc', 'h265', 'hvc1', 'hev1', 'bytevc1'];
const plain = e => ({ message: String(e?.message || e), code: e?.code || '' });
// 每个调用返回 Promise，结果统一回到原生 __done(callId, json)。
function wrap(callId, task) {
  Promise.resolve().then(task).then(
    value => Native.done(callId, JSON.stringify({ ok: true, value })),
    error => Native.done(callId, JSON.stringify({ ok: false, error: plain(error) })));
}
const controllers = new Map();
globalThis.HG = {
  browse(callId, category, page) { wrap(callId, async () => {
    const r = await browseList({ category, page });
    if (!r.success) throw Object.assign(new Error(r.error), { code: r.code });
    return r;
  }); },
  search(callId, keyword, page, cursor) { wrap(callId, () => searchApp(keyword, { page, cursor: cursor ? JSON.parse(cursor) : null })); },
  episodes(callId, sid) { wrap(callId, async () => parseDetail(await website(`/player/${sid}`), String(sid))); },
  // 只返回原生能播的编码；签名和 contentKey 原样透传，不改动。
  source(callId, vid, quality) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const s = await fetchAppPlayUrl(String(vid), { quality: quality || 'auto', signal: controller.signal });
        const variants = (s.variants || [s]).filter(v => PLAYABLE.includes(String(v.codec).toLowerCase()))
          .map(v => ({ url: v.url, contentKey: v.contentKey || null, codec: v.codec, quality: v.quality || s.quality || '', userAgent: v.userAgent || s.userAgent || '', referer: v.referer || '' }));
        if (!variants.length) throw Object.assign(new Error('本集只有 ByteVC2 编码，iOS 暂不支持'), { code: 'UNSUPPORTED_CODEC' });
        return { vid: String(vid), variants };
      } finally { controllers.delete(callId); }
    });
  },
  cancel(callId) { controllers.get(callId)?.abort(); },
};
globalThis.Buffer = Buffer;
Native.log('HG core ready');
