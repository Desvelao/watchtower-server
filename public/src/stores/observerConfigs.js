import { createListStore } from './createListStore';
import * as observerConfigsApi from '../services/api/observerConfigs';

export const useObserverConfigsStore = createListStore('observerConfigs', {
  filters: {
    name: '',
    search: '',
    observable_type_id: '',
    observer_type: '',
    created_after: '',
    created_before: '',
  },
  sort: 'id:asc',
  listFn: observerConfigsApi.listObserverConfigs,
  actions: {
    async create(payload) {
      const result = await observerConfigsApi.createObserverConfig(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await observerConfigsApi.updateObserverConfig(id, payload);
      await this.fetchList();
      return result;
    },
    async remove(id) {
      await observerConfigsApi.deleteObserverConfig(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => observerConfigsApi.deleteObserverConfig(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
