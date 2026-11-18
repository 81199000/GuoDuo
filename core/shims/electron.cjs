// 没有 Electron：上游 catalog.js 捕获 MODULE_NOT_FOUND 后走 axios 分支。
throw Object.assign(new Error('Cannot find module electron'), { code: 'MODULE_NOT_FOUND' });
