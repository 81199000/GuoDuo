// JavaScriptCore 没有浏览器/Node 宿主：补齐核心模块用到的最小环境。
import 'core-js/actual/url';
import 'core-js/actual/url-search-params';
import 'core-js/actual/structured-clone';
import 'core-js/actual/promise/any';
import 'core-js/actual/object/has-own';

const g = globalThis;
if (!g.console) g.console = { log: (...a) => Native.log(a.join(' ')), info: (...a) => Native.log(a.join(' ')), warn: (...a) => Native.log(a.join(' ')), error: (...a) => Native.log(a.join(' ')) };

// 计时器由原生 DispatchQueue 回调 __timerFire。
let timerSeq = 0; const timers = new Map();
g.__timerFire = id => { const t = timers.get(id); if (!t) return; timers.delete(id); t.fn(...t.args); };
g.setTimeout = (fn, ms = 0, ...args) => { const id = ++timerSeq; timers.set(id, { fn, args }); Native.timer(id, Math.max(0, Number(ms) || 0)); return id; };
g.clearTimeout = id => { timers.delete(id); };

// 只实现核心代码用到的 EventTarget / AbortController / AbortSignal 子集。
if (!g.EventTarget) {
  g.EventTarget = class {
    constructor() { this.__l = new Map(); }
    addEventListener(type, fn, opts) { if (!fn) return; const list = this.__l.get(type) || []; list.push({ fn, once: !!(opts && opts.once) }); this.__l.set(type, list); }
    removeEventListener(type, fn) { const list = this.__l.get(type); if (list) this.__l.set(type, list.filter(e => e.fn !== fn)); }
    dispatchEvent(event) { const list = [...(this.__l.get(event.type) || [])]; for (const e of list) { if (e.once) this.removeEventListener(event.type, e.fn); try { typeof e.fn === 'function' ? e.fn.call(this, event) : e.fn.handleEvent(event); } catch (err) { console.error('listener', err && err.message); } } return true; }
  };
}
if (!g.AbortSignal) {
  class AbortSignal extends g.EventTarget {
    constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    static timeout(ms) { const c = new g.AbortController(); setTimeout(() => c.abort(Object.assign(new Error('The operation timed out'), { name: 'TimeoutError' })), ms); return c.signal; }
    static abort(reason) { const c = new g.AbortController(); c.abort(reason); return c.signal; }
  }
  g.AbortSignal = AbortSignal;
  g.AbortController = class {
    constructor() { this.signal = new AbortSignal(); }
    abort(reason) {
      const s = this.signal; if (s.aborted) return;
      s.aborted = true; s.reason = reason === undefined ? Object.assign(new Error('This operation was aborted'), { name: 'AbortError' }) : reason;
      const ev = { type: 'abort', target: s }; if (typeof s.onabort === 'function') s.onabort(ev); s.dispatchEvent(ev);
    }
  };
}
