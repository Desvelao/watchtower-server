import { createListStore } from './createListStore';
import * as policiesApi from '../services/api/notification_policies';

export const useNotificationPoliciesStore = createListStore('notification_policies', {
  filters: {
    name: '',
    enabled: '',
    search: '',
    created_after: '',
    created_before: '',
  },
  sort: 'id:asc',
  listFn: policiesApi.listPolicies,
  actions: {
    async create(payload) {
      const result = await policiesApi.createPolicy(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await policiesApi.updatePolicy(id, payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await policiesApi.deletePolicy(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => policiesApi.deletePolicy(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
