import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

const base = process.env.APP_BASE || '/subwaysForNerds/';
export default defineConfig({
  base,
  plugins: [react(), {
    name: 'versioned-offline-shell',
    apply: 'build',
    closeBundle() {
      const assets = readdirSync('dist/assets').filter(name => !name.includes('bk-flame'));
      const version = createHash('sha256').update(assets.join('|') + readFileSync('dist/index.html', 'utf8') + readFileSync('public/sw.js', 'utf8')).digest('hex').slice(0, 12);
      const worker = readFileSync('public/sw.js', 'utf8').replace('__BUILD_VERSION__', version)
        .replace('/* __PRECACHE__ */', JSON.stringify(assets.map(name => 'assets/' + name)).slice(1, -1));
      writeFileSync('dist/sw.js', worker);
    },
  }],
  server: { proxy: { [base + 'api']: 'http://127.0.0.1:8091' } },
  build: { target: 'es2022' },
});
