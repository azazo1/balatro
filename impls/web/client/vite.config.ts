import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  server: {
    host: '127.0.0.1',
    strictPort: true,
    proxy: {
      '/api': { target: process.env.ENGINE_WEB_API ?? 'http://127.0.0.1:12347', changeOrigin: true },
    },
  },
});
