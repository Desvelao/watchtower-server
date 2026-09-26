import { createListStore } from './createListStore';
import * as observableTypesApi from '../services/api/observableTypes';

export const useObservableTypesStore = createListStore('observableTypes', {
  filters: {
    name: '',
    search: '',
    created_after: '',
    created_before: '',
  },
  sort: 'name:asc',
  listFn: observableTypesApi.listObservableTypes,
  actions: {
    async create(payload) {
      const result = await observableTypesApi.createObservableType(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await observableTypesApi.updateObservableType(id, payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await observableTypesApi.deleteObservableType(id);
      await this.fetchList();
    },
  },
});
