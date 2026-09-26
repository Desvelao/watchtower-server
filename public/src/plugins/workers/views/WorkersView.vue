<script setup>
import { onMounted, ref, computed } from 'vue';
import { useWorkersStore } from '../../../stores/workers';
import { useAuthStore } from '../../../stores/auth';
import { listWorkers, exportWorkersFile } from '../../../services/api/workers';
import { formatDate, formatUptime } from '../../../utils/date';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { schemaColumns, flattenProperties } from '../../entities/utils/flattenSchemaColumns';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { WORKER_ROLES, WORKER_ROLE_SCHEMAS } from '../workerRoleSchemas';
import { PERMISSIONS } from '../../../constants/permissions';

const CONNECTION_TYPES = ['http', 'mqtt', 'embedded'];

const BASE_COLUMNS = [
  { key: 'worker_id', label: 'Worker', class: 'font-medium', sortable: true },
  { key: 'roles', label: 'Roles' },
  { key: 'last_seen_at', label: 'Last seen', sortable: true },
];

// Worker's own fields already exist as fixed columns (not a `properties`
// schema, see workerRoleSchemas.js) - shown whenever "Observer" is selected
// (or no role filter is applied, since every real worker today is at
// least an observer).
const WORKER_COLUMNS = [
  { key: 'connection_type', label: 'Connection' },
  { key: 'capabilities', label: 'Capabilities' },
  { key: 'version', label: 'Version' },
  { key: 'uptime_seconds', label: 'Uptime' },
];

// Mirrors ObservablesListView.vue's "selecting a type changes the columns"
// pattern: no role selected -> today's full default view; "observer"
// selected -> the same view, explicitly; any other role -> its own
// `properties` schema columns instead.
const store = useWorkersStore();
const auth = useAuthStore();

const pendingAction = ref(null); // { type: 'delete', worker } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const exportFormat = ref('json');

const columns = computed(() => {
  if (!store.filters.role || store.filters.role === 'observer') {
    return [...BASE_COLUMNS, ...WORKER_COLUMNS];
  }
  return [...BASE_COLUMNS, ...schemaColumns(WORKER_ROLE_SCHEMAS[store.filters.role])];
});

// The capability dropdown must offer every capability across every
// worker, not just the current page - a small independent fetch of the
// full list, decoupled from the paginated main list, same pattern
// ObservablesListView.vue/JobsListView.vue use for their observable-type
// filter dropdown.
const allWorkers = ref([]);
onMounted(async () => {
  try {
    const { items } = await listWorkers();
    allWorkers.value = items || [];
  } catch {
    allWorkers.value = [];
  }
});

const capabilityOptions = computed(() => {
  const set = new Set();
  for (const w of allWorkers.value) {
    for (const c of w.capabilities || []) set.add(c);
  }
  return [...set].sort();
});

const otherFields = computed(() => [
  {
    key: 'role',
    label: 'Role',
    type: 'select',
    options: [{ value: '', label: 'All roles' }, ...WORKER_ROLES.map((t) => ({ value: t, label: t }))],
  },
  {
    key: 'connection_type',
    label: 'Connection',
    type: 'select',
    options: [{ value: '', label: 'Any' }, ...CONNECTION_TYPES.map((type) => ({ value: type, label: type }))],
  },
  {
    key: 'capability',
    label: 'Capability',
    type: 'select',
    options: [{ value: '', label: 'Any' }, ...capabilityOptions.value.map((c) => ({ value: c, label: c }))],
  },
]);

const searchField = { key: 'search', label: 'Search', placeholder: 'ID or version' };
const dateRangeField = { fromKey: 'last_seen_after', toKey: 'last_seen_before', label: 'Last seen' };

const { onFilterUpdate } = useFilterRouteSync(store);

// Spreads `properties` onto each row so a selected non-observer role's
// schema columns (e.g. analyzer's `observations_analyzed`) resolve via
// DataTable's existing plain `item[column.key]` fallback - same mechanism
// ObservablesListView.vue/ObservationsListView.vue already use.
const tableItems = computed(() => flattenProperties(store.items));

const hasActiveFilters = computed(() => Object.values(store.filters).some((v) => v));
const emptyText = computed(() =>
  store.totalItems === 0 && !hasActiveFilters.value ? 'No workers yet.' : 'No workers match the current filters.',
);

function askDelete(worker) {
  pendingAction.value = { type: 'delete', worker };
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
    await store.remove(action.worker.worker_id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportWorkersFile(store.buildExportQuery({ format: exportFormat.value }));
}
</script>

<template>
  <DataTable
    title="Workers"
    :columns="columns"
    :items="tableItems"
    id-key="worker_id"
    :loading="store.loading"
    :error="store.error ? 'Failed to load workers.' : null"
    :empty-text="emptyText"
    :sort="store.sort"
    :other-fields="otherFields"
    :search="searchField"
    :date-range="dateRangeField"
    :filters="store.filters"
    :selectable="auth.can(PERMISSIONS.WORKERS_DELETE)"
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
        v-if="auth.can(PERMISSIONS.WORKERS_READ)"
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
        Workers registered with the system. Filter by role to see the properties
        specific to that role.
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

    <template #cell-roles="{ value, filterBy }">
      <button
        v-for="t in value || []"
        :key="t"
        type="button"
        title="Filter by this role"
        class="mr-1 inline-block cursor-pointer rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
        @click="filterBy('role', t)"
      >
        {{ t }}
      </button>
      <span v-if="!(value || []).length" class="text-xs text-slate-400 dark:text-slate-500">—</span>
    </template>
    <template #cell-connection_type="{ value }">{{ value || '—' }}</template>
    <template #cell-capabilities="{ value, filterBy }">
      <button
        v-for="capability in value || []"
        :key="capability"
        type="button"
        title="Filter by this capability"
        class="mr-1 inline-block cursor-pointer rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
        @click="filterBy('capability', capability)"
      >
        {{ capability }}
      </button>
      <span v-if="!(value || []).length" class="text-xs text-slate-400 dark:text-slate-500">—</span>
    </template>
    <template #cell-version="{ value }">{{ value || '—' }}</template>
    <template #cell-uptime_seconds="{ value }">{{ formatUptime(value) }}</template>
    <template #cell-last_seen_at="{ value }">{{ value ? formatDate(value) : 'Never' }}</template>

    <template #row-actions="{ item: w }">
      <RouterLink
        :to="`/workers/${w.worker_id}`"
        title="View details"
        :aria-label="`View details for ${w.worker_id}`"
        class="inline-flex rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
      >
        <IconEye class="h-4 w-4" />
      </RouterLink>
      <button
        v-if="auth.can(PERMISSIONS.WORKERS_DELETE)"
        type="button"
        title="Delete"
        :aria-label="`Delete ${w.worker_id}`"
        class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
        @click="askDelete(w)"
      >
        <IconDelete class="h-4 w-4" />
      </button>
    </template>
  </DataTable>

  <ConfirmDialog
    :open="!!pendingAction"
    :title="pendingAction?.type === 'bulk-delete' ? 'Delete workers' : 'Delete worker'"
    :message="
      pendingAction
        ? pendingAction.type === 'bulk-delete'
          ? `Delete ${pendingAction.ids.length} selected workers? This cannot be undone.`
          : `Delete worker '${pendingAction.worker.worker_id}'?`
        : ''
    "
    confirm-label="Delete"
    @confirm="confirmPendingAction"
    @cancel="pendingAction = null"
  />
</template>
