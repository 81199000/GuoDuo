// iOS 没有 node:dns/net：只保留纯字符串判断（公网域名、无内网地址）。
const PRIVATE = /^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|0\.|::1$|fc|fd|fe80)/i;
function isPublicMediaUrl(value) {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return false;
    const host = url.hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '').toLowerCase();
    if (/^[\d.]+$/.test(host) || host.includes(':')) return !PRIVATE.test(host);
    return host.includes('.') && !/(^|\.)(localhost|local|internal|lan|home)$/.test(host);
  } catch (_) { return false; }
}
function webMediaRequestOptions() { return {}; }
module.exports = { isPublicMediaUrl, webMediaRequestOptions };
