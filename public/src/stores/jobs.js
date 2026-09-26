import { createListStore } from './createListStore';
import * as jobsApi from '../services/api/jobs';

export const useJobsStore = createListStore('jobs', {
  filters: {
    worker_id: '',
    type: '',
    status: '',
    ref_id: '',
    observable_type_id: '',
    search: '',
    created_after: '',
    created_before: '',
  },
  sort: 'id:desc',
  listFn: jobsApi.listJobs,
  actions: {
    async remove(id) {
      await jobsApi.deleteJob(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => jobsApi.deleteJob(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
