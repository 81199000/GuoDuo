// axios 的最小替身：走 Native.request。覆盖上游用到的 params / 对象 data / responseType / validateStatus / 跳转。
const transport = require('./transport.js').default;

function withParams(url, params) {
  if (!params) return url;
  const u = new URL(url);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) u.searchParams.set(k, String(v));
  return u.href;
}

async function axios(options) {
  if (typeof options === 'string') options = { url: options };
  let url = new URL(withParams(options.url, options.params));
  let data = options.data;
  const headers = { ...(options.headers || {}) };
  if (data != null && typeof data === 'object' && !(data instanceof Uint8Array) && !(data instanceof ArrayBuffer)) {
    data = JSON.stringify(data);
    if (!Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
  }
  const origin = url.origin;
  let response;
  for (let i = 0; i < 4; i++) {
    response = await transport({ ...options, headers, data, url: url.href, binary: options.responseType === 'arraybuffer' });
    if ([301, 302, 303, 307, 308].includes(response.status) && response.headers?.location && options.maxRedirects !== 0) {
      url = new URL(response.headers.location, url);
      if (url.protocol !== 'https:' || url.origin !== origin || url.username || url.password) throw new Error('来源跳转地址不受支持');
      continue;
    }
    break;
  }
  if (options.responseType === 'arraybuffer') {
    response.data = Buffer.from(response.data || '', 'base64');
  } else if (options.responseType === 'json' || (!options.responseType && !options.transformResponse)) {
    try { response.data = JSON.parse(response.data); } catch (_) { /* 非 JSON 保留原文 */ }
  }
  if (!(options.validateStatus ? options.validateStatus(response.status) : response.status >= 200 && response.status < 300)) {
    throw Object.assign(new Error(`请求失败（HTTP ${response.status}）`), { response, code: `HTTP_${response.status}` });
  }
  return response;
}
axios.get = (url, options = {}) => axios({ ...options, url });
axios.post = (url, data, options = {}) => axios({ ...options, url, data, method: 'POST' });
axios.isCancel = error => error?.code === 'ERR_CANCELED';
axios.default = axios;
module.exports = axios;
