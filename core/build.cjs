const path = require('node:path');
const esbuild = require('esbuild');
const s = p => path.join(__dirname, 'shims', p);
esbuild.buildSync({
  entryPoints: [path.join(__dirname, 'entry.js')],
  outfile: path.join(__dirname, '../HongGuo/Resources/hgcore.js'),
  bundle: true, format: 'iife', platform: 'neutral', mainFields: ['browser', 'module', 'main'], target: 'safari17', minify: true,
  inject: [s('env.js'), s('buffer-globals.js')],
  alias: { 'node:crypto': s('crypto.js'), 'node:zlib': s('zlib.js'), 'node:timers/promises': s('timers.cjs'), axios: s('axios.cjs') },
  legalComments: 'eof', logLevel: 'warning',
});
console.log('built hgcore.js');
