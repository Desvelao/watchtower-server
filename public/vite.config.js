import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue(), tailwindcss()],
  server: {
    port: 3000,
    host: true,
    proxy: {
      '/api': {
        target: 'http://server:8080',
        changeOrigin: true,
      },
    },
    cors: true,
  },
  test: {
    environment: 'jsdom',
    globals: true,
  },
});
