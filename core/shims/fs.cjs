// 只为账号登录态与弹幕匿名标识提供的极小文件系统：每个“文件”是钥匙串里的一条（Native.kv*）。
const enoent = () => Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
const open = new Map(); let fdSeq = 3;
module.exports = {
  existsSync: p => Native.kvGet(p) != null,
  readFileSync(p, enc) { const v = Native.kvGet(p); if (v == null) throw enoent(); return enc ? v : Buffer.from(v, 'utf8'); },
  writeFileSync(p, data, opts) {
    const text = Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
    if (typeof p === 'number') { open.set(p, { ...open.get(p), text }); return; }
    if (opts && opts.flag === 'wx' && Native.kvGet(p) != null) throw Object.assign(new Error('EEXIST'), { code: 'EEXIST' });
    Native.kvSet(p, text);
  },
  openSync(p) { const fd = fdSeq++; open.set(fd, { path: p, text: '' }); return fd; },
  fsyncSync() {},
  closeSync(fd) { const f = open.get(fd); open.delete(fd); if (f) Native.kvSet(f.path, f.text); },
  renameSync(a, b) { const v = Native.kvGet(a); if (v == null) throw enoent(); Native.kvSet(b, v); Native.kvDel(a); },
  unlinkSync(p) { if (Native.kvGet(p) == null) throw enoent(); Native.kvDel(p); },
  mkdirSync() {}, chmodSync() {},
};
