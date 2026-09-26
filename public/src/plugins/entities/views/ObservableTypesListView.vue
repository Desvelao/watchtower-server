<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import ObservableTypeDetailsFlyout from '../components/ObservableTypeDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportObservableTypesFile, importObservableTypesFile } from '../../../services/api/observableTypes';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', observableType }
const actionError = ref('');
const importing = ref(false);
const importError = ref('');

onMounted(() => store.fetchList());

const columns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'label', label: 'Label' },
  { key: 'description', label: 'Description', class: 'text-slate-600 dark:text-slate-400' },
  { key: 'created_at', label: 'Created', sortable: true },
];

const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsObservableTypeId = computed(() => route.query.details || null);

function viewDetails(observableType) {
  router.push({ query: { ...route.query, details: observableType.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(observableType) {
  router.push(`/observable-types/${observableType.id}/edit`);
}

function askDelete(observableType) {
  pendingAction.value = { type: 'delete', observableType };
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  actionError.value = '';
  try {
    await store.remove(action.observableType.id);
  } catch (err) {
    actionError.value = err.response?.body?.message || 'Failed to delete observable type.';
  }
}

async function onExport() {
  await exportObservableTypesFile();
}

async function onImportChange(event) {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  importError.value = '';
  importing.value = true;
  try {
    await importObservableTypesFile(file);
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
      title="Observable Types"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load observable types.' : null"
      empty-text="No observable types found."
      :sort="store.sort"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
    >
      <template #header-actions>
        <label
          v-if="auth.can(PERMISSIONS.OBSERVABLE_TYPES_CREATE)"
          class="flex cursor-pointer items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconUpload class="h-4 w-4" />
          {{ importing ? 'Importing...' : 'Import' }}
          <input type="file" class="hidden" :disabled="importing" @change="onImportChange" />
        </label>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLE_TYPES_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.OBSERVABLE_TYPES_CREATE)"
          to="/observable-types/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Observable Type
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          An observable type declares the properties used to create Items of that type, and the shape of the
          Observations recorded for them.
        </p>
      </template>

      <template #messages>
        <p v-if="importError" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ importError }}</p>
        <p v-if="actionError" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ actionError }}</p>
      </template>

      <template #cell-created_at="{ value }">{{ formatDate(value) }}</template>

      <template #row-actions="{ item: observableType }">
        <button
          type="button"
          title="View details"
          aria-label="View observable type details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(observableType)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLE_TYPES_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit observable type"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(observableType)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.OBSERVABLE_TYPES_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete observable type"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(observableType)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      title="Delete observable type"
      :message="pendingAction ? `Delete observable type '${pendingAction.observableType.name}'?` : ''"
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <ObservableTypeDetailsFlyout :observable-type-id="detailsObservableTypeId" @close="closeDetails" />
  </div>
</template>
