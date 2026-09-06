import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  base: process.env.APP_BASE || '/subwaysForNerds/',
  plugins: [react()],
  server: { proxy: { '/subwaysForNerds/api': 'http://127.0.0.1:8091' } },
  build: { target: 'es2022' },
});
