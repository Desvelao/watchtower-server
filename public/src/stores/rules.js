import { createListStore } from './createListStore';
import * as rulesApi from '../services/api/rules';

export const useRulesStore = createListStore('rules', {
  filters: {
    name: '',
    action: '',
    enabled: '',
    search: '',
  },
  sort: 'id:asc',
  listFn: rulesApi.listRules,
  actions: {
    async create(payload) {
      const result = await rulesApi.createRule(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await rulesApi.updateRule(id, payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await rulesApi.deleteRule(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => rulesApi.deleteRule(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
