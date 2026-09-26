import { createListStore } from './createListStore';
import * as observationsApi from '../services/api/observations';

export const useObservationsStore = createListStore('observations', {
  filters: {
    id: '',
    observable_type_id: '',
    search: '',
    timestamp_after: '',
    timestamp_before: '',
  },
  sort: 'timestamp:desc',
  listFn: observationsApi.listObservations,
  actions: {
    async remove(id) {
      await observationsApi.deleteObservation(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => observationsApi.deleteObservation(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
