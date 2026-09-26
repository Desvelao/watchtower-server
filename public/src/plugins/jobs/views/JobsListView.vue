<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useJobsStore } from '../../../stores/jobs';
import { useAuthStore } from '../../../stores/auth';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { getObservable } from '../../../services/api/observables';
import { getTask } from '../../../services/api/scheduler';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import AlertStatusBadge from '../../../components/AlertStatusBadge.vue';
import JobDetailsFlyout from '../components/JobDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportJobsFile } from '../../../services/api/jobs';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';
import { schemaColumns } from '../../entities/utils/flattenSchemaColumns';

const store = useJobsStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();
const observableTypesStore = useObservableTypesStore();

const pendingAction = ref(null); // { type: 'delete', job } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const exportFormat = ref('json');

if (!observableTypesStore.items.length) observableTypesStore.fetchList();

const fixedColumns = [
  { key: 'id', label: 'ID' },
  { key: 'type', label: 'Type' },
  { key: 'ref_id', label: 'Ref' },
  { key: 'worker_id', label: 'Worker' },
  { key: 'status', label: 'Status', sortable: true },
];
const trailingColumns = [
  { key: 'action', label: 'Action', class: 'text-xs text-slate-600 dark:text-slate-400' },
  { key: 'message', label: 'Message', class: 'text-xs text-slate-600 dark:text-slate-400' },
  { key: 'retries', label: 'Retries' },
  { key: 'created_at', label: 'Created', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'taken_at', label: 'Taken at', class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'acked_at', label: 'Acked at', class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'error_at', label: 'Last error', class: 'whitespace-nowrap' },
];

// ref_id is polymorphic (see config/dataset/init.sql's comment on
// jobs.from_scheduler): from_scheduler=true -> a scheduler_tasks.id,
// from_scheduler=false -> an observables.id. Resolved lazily, one GET per
// unique id (cached here), since GET /api/observables|scheduler only
// filters `id` by exact equality, not a batch/IN list.
const observableCache = reactive({});
const taskCache = reactive({});

async function ensureResolved(job) {
  if (job.from_scheduler) {
    if (taskCache[job.ref_id] !== undefined) return;
    taskCache[job.ref_id] = null;
    try {
      const { item } = await getTask(job.ref_id);
      taskCache[job.ref_id] = item || null;
    } catch {
      taskCache[job.ref_id] = null;
    }
  } else {
    if (observableCache[job.ref_id] !== undefined) return;
    observableCache[job.ref_id] = null;
    try {
      const { observable } = await getObservable(job.ref_id);
      observableCache[job.ref_id] = observable || null;
    } catch {
      observableCache[job.ref_id] = null;
    }
  }
}

watch(
  () => store.items,
  (jobs) => {
    for (const job of jobs) ensureResolved(job);
  },
  { immediate: true },
);

function refLabel(job) {
  if (job.from_scheduler) {
    const task = taskCache[job.ref_id];
    return task ? `${task.name} (${task.type})` : `task #${job.ref_id}`;
  }
  const observable = observableCache[job.ref_id];
  return observable ? observable.name : `observable #${job.ref_id}`;
}

// When the observable_type_id filter narrows to one type, add that type's
// `properties` schema fields as columns, populated from each from_scheduler
// =false row's resolved observable (from_scheduler=true rows have no
// observable, so they render blank) - same pattern ObservablesListView.vue/
// SchedulerTasksListView.vue use.
const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(store.filters.observable_type_id)),
);
const columns = computed(() => {
  const dynamic = selectedObservableType.value ? schemaColumns(selectedObservableType.value.properties) : [];
  return [...fixedColumns, ...dynamic, ...trailingColumns];
});
const tableItems = computed(() =>
  store.items.map((job) => ({
    ...job,
    ...(job.from_scheduler ? {} : observableCache[job.ref_id]?.properties || {}),
  })),
);

const otherFields = computed(() => [
  { key: 'worker_id', label: 'Worker', type: 'text' },
  { key: 'ref_id', label: 'Ref ID', type: 'text' },
  {
    key: 'type',
    label: 'Type',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'observe', label: 'Observe' },
      { value: 'analyze', label: 'Analyze' },
      { value: 'notify', label: 'Notify' },
    ],
  },
  {
    key: 'observable_type_id',
    label: 'Observable type',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      ...observableTypesStore.items.map((t) => ({ value: String(t.id), label: t.label || t.name })),
    ],
  },
  {
    key: 'status',
    label: 'Status',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'pending', label: 'Pending' },
      { value: 'triggering', label: 'Triggering' },
      { value: 'acknowledged', label: 'Acknowledged' },
      { value: 'error', label: 'Error' },
    ],
  },
]);

const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

// Deep-links a filter (e.g. a "Worker" link elsewhere in the app) via
// matching query params.
const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsJobId = computed(() => route.query.details || null);

function viewDetails(job) {
  router.push({ query: { ...route.query, details: job.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function viewWorker(job) {
  router.push(`/workers/${job.worker_id}`);
}

function askDelete(job) {
  pendingAction.value = { type: 'delete', job };
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
    await store.remove(action.job.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportJobsFile(store.buildExportQuery({ format: exportFormat.value }));
}
</script>

<template>
  <div>
    <DataTable
      title="Jobs"
      :columns="columns"
      :items="tableItems"
      :loading="store.loading"
      :error="store.error ? 'Failed to load jobs.' : null"
      empty-text="No jobs found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.JOBS_DELETE)"
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
          v-if="auth.can(PERMISSIONS.JOBS_READ)"
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
          One row per (worker, type, ref) work assignment a worker has reported on - status,
          timestamps, and any error recorded along the way.
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

      <template #cell-status="{ item: job }">
        <AlertStatusBadge :status="job.status" />
      </template>

      <template #cell-ref_id="{ item: job }">
        <span :title="`ref_id: ${job.ref_id}`">{{ refLabel(job) }}</span>
      </template>

      <template #cell-created_at="{ item: job }">{{ formatDate(job.created_at) }}</template>
      <template #cell-taken_at="{ item: job }">{{ formatDate(job.taken_at) }}</template>
      <template #cell-acked_at="{ item: job }">{{ formatDate(job.acked_at) }}</template>

      <template #cell-message="{ item: job }">
        <span class="block max-w-[280px] truncate" :title="job.message || ''">
          {{ job.message || '—' }}
        </span>
      </template>

      <template #cell-error_at="{ item: job }">
        <span :class="job.error_at ? 'text-red-600 dark:text-red-400' : ''">
          {{ formatDate(job.error_at) }}
        </span>
      </template>

      <template #row-actions="{ item: job }">
        <button
          type="button"
          title="View details"
          aria-label="View job details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(job)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.WORKERS_READ)"
          type="button"
          title="View worker"
          class="rounded px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewWorker(job)"
        >
          {{ job.worker_id }}
        </button>
        <button
          v-if="auth.can(PERMISSIONS.JOBS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete job"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(job)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete jobs' : 'Delete job'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected jobs? This cannot be undone.`
            : `Delete job #${pendingAction.job.id}?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <JobDetailsFlyout :job-id="detailsJobId" @close="closeDetails" />
  </div>
</template>
