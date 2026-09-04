import { createListStore } from './createListStore';
import * as jobsApi from '../services/api/jobs';

export const useJobsStore = createListStore('jobs', {
  filters: {
    monitor_id: '',
    type: '',
    status: '',
    ref_id: '',
    search: '',
  },
  sort: 'id:desc',
  listFn: jobsApi.listJobs,
});
