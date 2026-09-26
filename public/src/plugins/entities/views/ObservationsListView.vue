<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObservationsStore } from '../../../stores/observations';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import ObservationDetailsFlyout from '../components/ObservationDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportObservationsFile } from '../../../services/api/observations';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';
import { schemaColumns, flattenProperties } from '../utils/flattenSchemaColumns';
import { observableTypeLabel } from '../../../utils/observableType';
import { formatDate } from '../../../utils/date';

const store = useObservationsStore();
const observableTypesStore = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', observation } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const exportFormat = ref('json');

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(store.filters.observable_type_id)),
);

const fixedColumns = [
  { key: 'timestamp', label: 'Date', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'observable', label: 'Observable' },
  { key: 'type', label: 'Type' },
  { key: 'worker', label: 'Worker' },
];

const columns = computed(() => {
  const dynamic = selectedObservableType.value ? schemaColumns(selectedObservableType.value.observation_schema) : [];
  return [...fixedColumns, ...dynamic];
});

const tableItems = computed(() => flattenProperties(store.items));

const otherFields = computed(() => [
  {
    key: 'observable_type_id',
    label: 'Observable type',
    type: 'select',
    options: [{ value: '', label: 'All types' }, ...observableTypesStore.items.map((t) => ({ value: String(t.id), label: t.label || t.name }))],
  },
]);

const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'timestamp_after', toKey: 'timestamp_before', label: 'Date' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsObservationId = computed(() => route.query.details || null);

function viewDetails(observation) {
  router.push({ query: { ...route.query, details: observation.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function askDelete(observation) {
  pendingAction.value = { type: 'delete', observation };
}

function askBulkDelete(ids) {
  pendingAction.value = { type: 'bulk-delete', ids: [...ids] };
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = '';
  if (action.type === 'delete') {
    await store.remove(action.observation.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportObservationsFile(store.buildExportQuery({ format: exportFormat.value }));
}
</script>

<template>
  <div>
    <DataTable
      title="Observations"
      :columns="columns"
      :items="tableItems"
      :loading="store.loading"
      :error="store.error ? 'Failed to load observations.' : null"
      empty-text="No observations found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.OBSERVATIONS_DELETE)"
      :pagination="store.pagination"
      :total-items="store.totalItems"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
      @update:from="store.setPage"
      @update:size="store.setPageSize"
    >
      <template #header-actions>
        <select
          v-model="exportFormat"
          class="rounded border border-slate-300 px-2 py-1.5 text-sm text-slate-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-300"
        >
          <option value="json">JSON</option>
          <option value="csv">CSV</option>
        </select>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVATIONS_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Filter by observable type to see its observation fields marked "Show as column" as extra columns.
          Observations are ingested via the API, not created here.
        </p>
      </template>

      <template #messages>
        <p v-if="bulkError" class="mt-4 text-sm text-amber-700 dark:text-amber-400">{{ bulkError }}</p>
      </template>

      <template #bulk-actions="{ selectedIds }">
        <button
          type="button"
          class="flex items-center gap-1.5 rounded p-1.5 text-sm font-medium text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askBulkDelete(selectedIds)"
        >
          <IconDelete class="h-4 w-4" />
          Delete selected
        </button>
      </template>

      <template #cell-timestamp="{ value }">{{ formatDate(value) }}</template>

      <template #cell-observable="{ item: observation }">
        {{ observation.observable?.name ?? '-' }}
      </template>

      <template #cell-type="{ item: observation }">
        {{ observableTypeLabel(observation.observable?.observable_type_id, observableTypesStore.items) }}
      </template>

      <template #cell-url="{ value }">
        <a v-if="value" :href="value" target="_blank" rel="noopener noreferrer" class="underline hover:text-slate-900 dark:hover:text-slate-100">
          {{ value }}
        </a>
        <span v-else>-</span>
      </template>

      <template #cell-available="{ value }">
        <span>{{ value ? '✅' : '-' }}</span>
      </template>

      <template #row-actions="{ item: observation }">
        <button
          type="button"
          title="View details"
          aria-label="View observation details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(observation)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVATIONS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete observation"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(observation)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete observations' : 'Delete observation'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected observations? This cannot be undone.`
            : `Delete observation #${pendingAction.observation.id}?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <ObservationDetailsFlyout :observation-id="detailsObservationId" @close="closeDetails" />
  </div>
</template>
