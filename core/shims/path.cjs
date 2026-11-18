module.exports = { dirname: p => String(p).replace(/\/[^/]*$/, '') || '/', join: (...a) => a.join('/'), basename: p => String(p).split('/').pop() };
