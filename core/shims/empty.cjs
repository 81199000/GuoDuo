// electron / node:fs / node:path 在 iOS 核心里不可用：调用即报错，由上游代码的降级分支处理。
const fail = () => { const e = new Error('不支持'); e.code = 'MODULE_NOT_FOUND'; throw e; };
module.exports = new Proxy({}, { get: (_, k) => k === '__esModule' ? false : fail });
