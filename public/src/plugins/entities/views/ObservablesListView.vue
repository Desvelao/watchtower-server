<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObservablesStore } from '../../../stores/observables';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import EnabledBadge from '../../../components/common/EnabledBadge.vue';
import ObservableDetailsFlyout from '../components/ObservableDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportObservablesFile, importObservablesFile } from '../../../services/api/observables';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';
import { schemaColumns, flattenProperties } from '../utils/flattenSchemaColumns';

const store = useObservablesStore();
const observableTypesStore = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', observable } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const importing = ref(false);
const importError = ref('');

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(store.filters.observable_type_id)),
);

const fixedColumns = [
  { key: 'enabled', label: 'Enabled', sortable: true },
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
];
const trailingColumns = [
  { key: 'created_at', label: 'Created', sortable: true },
  { key: 'updated_at', label: 'Updated', sortable: true },
];

const columns = computed(() => {
  const dynamic = selectedObservableType.value ? schemaColumns(selectedObservableType.value.properties) : [];
  return [...fixedColumns, ...dynamic, ...trailingColumns];
});

const tableItems = computed(() => flattenProperties(store.items));

const otherFields = computed(() => [
  {
    key: 'observable_type_id',
    label: 'Observable type',
    type: 'select',
    options: [{ value: '', label: 'All types' }, ...observableTypesStore.items.map((t) => ({ value: String(t.id), label: t.label || t.name }))],
  },
  { key: 'name', label: 'Name', type: 'text' },
  {
    key: 'enabled',
    label: 'Enabled',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'true', label: 'Enabled' },
      { value: 'false', label: 'Disabled' },
    ],
  },
]);

const searchField = { key: 'search', label: 'Search' };
const dateRangeFields = [
  { fromKey: 'created_after', toKey: 'created_before', label: 'Created' },
  { fromKey: 'updated_after', toKey: 'updated_before', label: 'Updated' },
];

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsObservableId = computed(() => route.query.details || null);

function viewDetails(observable) {
  router.push({ query: { ...route.query, details: observable.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(observable) {
  router.push(`/observables/${observable.id}/edit`);
}

function askDelete(observable) {
  pendingAction.value = { type: 'delete', observable };
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
    await store.remove(action.observable.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportObservablesFile();
}

async function onImportChange(event) {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  importError.value = '';
  importing.value = true;
  try {
    await importObservablesFile(file);
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
      title="Observables"
      :columns="columns"
      :items="tableItems"
      :loading="store.loading"
      :error="store.error ? 'Failed to load observables.' : null"
      empty-text="No observables found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-ranges="dateRangeFields"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.OBSERVABLES_DELETE)"
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
          v-if="auth.can(PERMISSIONS.OBSERVABLES_CREATE)"
          class="flex cursor-pointer items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconUpload class="h-4 w-4" />
          {{ importing ? 'Importing...' : 'Import' }}
          <input type="file" class="hidden" :disabled="importing" @change="onImportChange" />
        </label>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLES_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.OBSERVABLES_CREATE)"
          to="/observables/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Observable
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Filter by observable type to see its properties marked "Show as column" as extra columns.
        </p>
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

      <template #cell-enabled="{ value }">
        <EnabledBadge :enabled="value" />
      </template>

      <template #cell-url="{ value }">
        <a v-if="value" :href="value" target="_blank" rel="noopener noreferrer" class="underline hover:text-slate-900 dark:hover:text-slate-100">
          {{ value }}
        </a>
        <span v-else>-</span>
      </template>

      <template #cell-created_at="{ value }">{{ formatDate(value) }}</template>
      <template #cell-updated_at="{ value }">{{ formatDate(value) }}</template>

      <template #row-actions="{ item: observable }">
        <button
          type="button"
          title="View details"
          aria-label="View observable details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(observable)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLES_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit observable"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(observable)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLES_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete observable"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(observable)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete observables' : 'Delete observable'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected observables? This cannot be undone.`
            : `Delete observable '${pendingAction.observable.name}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <ObservableDetailsFlyout :observable-id="detailsObservableId" @close="closeDetails" />
  </div>
</template>
