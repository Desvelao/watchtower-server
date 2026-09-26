import { createListStore } from './createListStore';
import * as observablesApi from '../services/api/observables';

export const useObservablesStore = createListStore('observables', {
  filters: {
    enabled: '',
    name: '',
    observable_type_id: '',
    search: '',
    created_after: '',
    created_before: '',
    updated_after: '',
    updated_before: '',
  },
  sort: 'id:asc',
  listFn: observablesApi.listObservables,
  actions: {
    async create(payload) {
      const result = await observablesApi.createObservable(payload);
      await this.fetchList();
      return result.observable;
    },
    async update(id, payload) {
      const result = await observablesApi.updateObservable(id, payload);
      await this.fetchList();
      return result.observable;
    },
    async remove(id) {
      await observablesApi.deleteObservable(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => observablesApi.deleteObservable(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
