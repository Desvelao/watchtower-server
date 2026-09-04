import { defineStore } from 'pinia';
import * as authApi from '../services/api/auth';

const STORAGE_KEY = 'price_monitor_auth';

export const useAuthStore = defineStore('auth', {
  state: () => ({
    token: null,
    role: null,
    username: null,
    permissions: [],
  }),
  getters: {
    isAuthenticated: (state) => !!state.token,
  },
  actions: {
    // Async: if a token was persisted, re-fetches /api/auth/me so a stale
    // persisted `permissions` array (e.g. a role edited server-side since
    // the last visit) self-heals on every app load, instead of trusting
    // whatever was last written to localStorage.
    async restore() {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      try {
        const { token, role, username, permissions } = JSON.parse(raw);
        this.token = token ?? null;
        this.role = role ?? null;
        this.username = username ?? null;
        this.permissions = permissions ?? [];
      } catch {
        localStorage.removeItem(STORAGE_KEY);
        return;
      }

      if (this.token) {
        try {
          await this.refreshMe();
        } catch {
          // Token may have expired/been revoked since last visit - leave
          // the stale state in place, the next authenticated request will
          // 401 and http.js's own logout() handles it from there.
        }
      }
    },
    persist() {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          token: this.token,
          role: this.role,
          username: this.username,
          permissions: this.permissions,
        }),
      );
    },
    async refreshMe() {
      const { role, username, permissions } = await authApi.getMe();
      this.role = role;
      this.username = username;
      this.permissions = permissions ?? [];
      this.persist();
    },
    async login(username, password) {
      const { token } = await authApi.login(username, password);
      this.token = token;
      this.username = username;
      await this.refreshMe();
    },
    logout() {
      this.token = null;
      this.role = null;
      this.username = null;
      this.permissions = [];
      localStorage.removeItem(STORAGE_KEY);
    },
    can(permission) {
      return this.permissions.includes(permission);
    },
  },
});
