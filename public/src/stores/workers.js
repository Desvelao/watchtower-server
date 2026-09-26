import { createListStore } from './createListStore';
import * as workersApi from '../services/api/workers';

export const useWorkersStore = createListStore('workers', {
  filters: {
    role: '',
    connection_type: '',
    capability: '',
    search: '',
    last_seen_after: '',
    last_seen_before: '',
  },
  sort: 'worker_id:asc',
  listFn: workersApi.listWorkers,
  actions: {
    async remove(id) {
      await workersApi.deleteWorker(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => workersApi.deleteWorker(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
