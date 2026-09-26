import { createListStore } from './createListStore';
import * as deliveriesApi from '../services/api/alert_deliveries';

export const useDeliveriesStore = createListStore('deliveries', {
  filters: {
    channel_id: '',
    status: '',
    search: '',
    notified_after: '',
    notified_before: '',
  },
  sort: 'updated_at:desc',
  listFn: deliveriesApi.listDeliveries,
});
