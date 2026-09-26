import { createListStore } from './createListStore';
import * as alertsApi from '../services/api/alerts';
import { relativeDateKeyword } from '../utils/date';

export const useAlertsStore = createListStore('alerts', {
  filters: {
    id: '',
    observation_id: '',
    severity: '',
    source: '',
    tags: '',
    rule_id: '',
    observable_type_id: '',
    search: '',
    created_after: relativeDateKeyword(24),
    created_before: '',
  },
  sort: 'created_at:desc',
  listFn: alertsApi.listAlerts,
  actions: {
    async remove(id) {
      await alertsApi.deleteAlert(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => alertsApi.deleteAlert(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
