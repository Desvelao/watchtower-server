import { defineStore } from 'pinia';
import * as monitorsApi from '../services/api/monitors';

// Small and unpaginated (the registry only ever has a handful of active
// worker instances) - a plain state/action store rather than
// createListStore, which is built around server-side pagination.
export const useMonitorsStore = defineStore('monitors', {
  state: () => ({
    items: [],
    loading: false,
    error: null,
  }),
  actions: {
    async fetchList() {
      this.loading = true;
      this.error = null;
      try {
        const { items } = await monitorsApi.listMonitors();
        this.items = items || [];
      } catch (err) {
        this.error = err;
        throw err;
      } finally {
        this.loading = false;
      }
    },
    findById(id) {
      return this.items.find((item) => String(item.monitor_id) === String(id));
    },
  },
});
