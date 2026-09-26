<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObserverConfigsStore } from '../../../stores/observerConfigs';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import ObserverConfigDetailsFlyout from '../components/ObserverConfigDetailsFlyout.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import IconFlask from '../../../components/common/icons/IconFlask.vue';
import { exportObserverConfigsFile, importObserverConfigsFile } from '../../../services/api/observerConfigs';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useObserverConfigsStore();
const observableTypesStore = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', item } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const importing = ref(false);
const importError = ref('');

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

function observableTypeLabel(id) {
  const type = observableTypesStore.items.find((t) => String(t.id) === String(id));
  return type ? type.label || type.name : id;
}

const baseColumns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'observable_type_id', label: 'Observable type' },
  { key: 'enabled', label: 'Enabled', sortable: true },
  { key: 'created_at', label: 'Created', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
];

// Extra columns, derived from the single selected observable type's own
// observer_config_schema/observer_mechanism_schema fields marked
// list_column - empty (falling back to baseColumns alone) whenever the
// "Observable type" filter isn't narrowed to exactly one type.
const selectedObservableType = computed(() => {
  const id = store.filters.observable_type_id;
  if (!id) return null;
  return observableTypesStore.items.find((t) => String(t.id) === String(id)) || null;
});

const extraColumns = computed(() => {
  const type = selectedObservableType.value;
  if (!type) return [];

  const fieldColumns = (type.observer_config_schema || [])
    .filter((prop) => prop.list_column)
    .map((prop) => ({ key: `field__${prop.name}`, label: prop.label || prop.name, source: 'field', name: prop.name }));

  const mechColumns = (type.observer_mechanism_schema || [])
    .filter((prop) => prop.list_column)
    .map((prop) => ({ key: `mech__${prop.name}`, label: prop.label || prop.name, source: 'mechanism', name: prop.name }));

  return [...fieldColumns, ...mechColumns];
});

const columns = computed(() => [...baseColumns, ...extraColumns.value]);

function formatMechanismValue(value) {
  if (value == null || value === '') return '—';
  if (Array.isArray(value)) return value.length ? value.join(', ') : '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'object') return Object.keys(value).length ? JSON.stringify(value) : '—';
  return String(value);
}

function extraColumnValue(item, column) {
  if (column.source === 'field') {
    const row = item.fields?.[column.name];
    if (!row) return '—';
    if (row.compute) return row.compute;
    const selector = (row.selector || []).filter(Boolean);
    return selector.length ? selector.join(' | ') : '—';
  }

  return formatMechanismValue(item.mechanism_config?.[column.name]);
}

const displayItems = computed(() => {
  if (!extraColumns.value.length) return store.items;
  return store.items.map((item) => {
    const extra = {};
    for (const column of extraColumns.value) {
      extra[column.key] = extraColumnValue(item, column);
    }
    return { ...item, ...extra };
  });
});

const otherFields = computed(() => [
  {
    key: 'observable_type_id',
    label: 'Observable type',
    type: 'select',
    options: [{ value: '', label: 'All types' }, ...observableTypesStore.items.map((t) => ({ value: String(t.id), label: t.label || t.name }))],
  },
  { key: 'name', label: 'Name', type: 'text' },
]);
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsConfigId = computed(() => route.query.details || null);

function viewDetails(item) {
  router.push({ query: { ...route.query, details: item.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(item) {
  router.push(`/observer_configs/${item.id}/edit`);
}

function askDelete(item) {
  pendingAction.value = { type: 'delete', item };
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
    await store.remove(action.item.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportObserverConfigsFile();
}

async function onImportChange(event) {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  importError.value = '';
  importing.value = true;
  try {
    await importObserverConfigsFile(file);
    await store.fetchList();
  } catch (err) {
    importError.value = 'Import failed.';
  } finally {
    importing.value = false;
  }
}
</script>

<template>
  <div>
    <DataTable
      title="Observer Configs"
      :columns="columns"
      :items="displayItems"
      :loading="store.loading"
      :error="store.error ? 'Failed to load observer configs.' : null"
      empty-text="No observer configs found."
      :sort="store.sort"
      :other-fields="otherFields"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.OBSERVER_CONFIGS_DELETE)"
      :pagination="store.pagination"
      :total-items="store.totalItems"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
      @update:from="store.setPage"
      @update:size="store.setPageSize"
    >
      <template #header-actions>
        <label
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_CREATE)"
          class="flex cursor-pointer items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconUpload class="h-4 w-4" />
          {{ importing ? 'Importing...' : 'Import' }}
          <input type="file" class="hidden" :disabled="importing" @change="onImportChange" />
        </label>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_CREATE)"
          to="/observer_configs/test"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconFlask class="h-4 w-4" />
          Test all
        </RouterLink>
        <RouterLink
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_CREATE)"
          to="/observer_configs/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Observer Config
        </RouterLink>
      </template>

      <template #messages>
        <p v-if="importError" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ importError }}</p>
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

      <template #cell-observable_type_id="{ value }">{{ observableTypeLabel(value) }}</template>
      <template #cell-enabled="{ value }">{{ value ? 'Yes' : 'No' }}</template>
      <template #cell-created_at="{ value }">{{ formatDate(value) }}</template>

      <template #row-actions="{ item }">
        <button
          type="button"
          title="View details"
          aria-label="View details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(item)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(item)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVER_CONFIGS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(item)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete observer configs' : 'Delete observer config'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected observer configs? This cannot be undone.`
            : `Delete observer config '${pendingAction.item.name}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <ObserverConfigDetailsFlyout :config-id="detailsConfigId" @close="closeDetails" />
  </div>
</template>
