<script setup>
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useSchedulerStore } from '../../../stores/scheduler';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import { formatDate } from '../../../utils/date';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import EnabledBadge from '../../../components/common/EnabledBadge.vue';
import SchedulerTaskDetailsFlyout from '../components/SchedulerTaskDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconTrigger from '../../../components/common/icons/IconTrigger.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportTasksFile, importTasksFile } from '../../../services/api/scheduler';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';
import { schemaColumns } from '../../entities/utils/flattenSchemaColumns';

const store = useSchedulerStore();
const observableTypesStore = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

if (!observableTypesStore.items.length) observableTypesStore.fetchList();

const pendingDelete = ref(null);
const runningNowId = ref(null);
const importing = ref(false);
const importError = ref('');

const fixedColumns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'type', label: 'Type', sortable: true },
  { key: 'observable_type_id', label: 'Observable type' },
  { key: 'target', label: 'Target' },
  { key: 'schedule', label: 'Schedule' },
];
const trailingColumns = [
  { key: 'enabled', label: 'Enabled', sortable: true },
  { key: 'next_run_at', label: 'Next run' },
  { key: 'last_run_at', label: 'Last run' },
  { key: 'created_at', label: 'Created', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
];

// When the observable_type_id filter narrows to one type, add that type's
// `properties` schema fields as reference columns - same pattern
// ObservablesListView.vue/ObservationsListView.vue already use. A task row
// rarely has values for these (it's not an observable), but it keeps this
// list visually consistent with the rest of the app; notify tasks
// (observable_type_id is always null) are naturally excluded by this filter.
const selectedObservableType = computed(() =>
  observableTypesStore.items.find((t) => String(t.id) === String(store.filters.observable_type_id)),
);
const columns = computed(() => {
  const dynamic = selectedObservableType.value ? schemaColumns(selectedObservableType.value.properties) : [];
  return [...fixedColumns, ...dynamic, ...trailingColumns];
});

const otherFields = computed(() => [
  {
    key: 'type',
    label: 'Type',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'observe', label: 'Observe' },
      { value: 'analyze', label: 'Analyze' },
      { value: 'notify', label: 'Notify' },
      { value: 'deliver', label: 'Deliver' },
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
    key: 'schedule_type',
    label: 'Schedule',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'cron', label: 'Cron' },
      { value: 'one_shot', label: 'One-shot' },
    ],
  },
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
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsTaskId = computed(() => route.query.details || null);

function viewDetails(task) {
  router.push({ query: { ...route.query, details: task.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function observableTypeLabel(id) {
  if (!id) return '—';
  const t = observableTypesStore.items.find((et) => et.id === id);
  return t ? t.label || t.name : `#${id}`;
}

function targetSummary(task) {
  if (task.type === 'notify') {
    return task.notify_policy_ids && task.notify_policy_ids.length
      ? `${task.notify_policy_ids.length} specific polic${task.notify_policy_ids.length === 1 ? 'y' : 'ies'}`
      : 'All policies';
  }
  if (task.type === 'deliver') {
    return 'Delivery queue';
  }
  return task.observable_ids && task.observable_ids.length ? `${task.observable_ids.length} observable(s)` : 'All observables';
}

function scheduleSummary(task) {
  return task.schedule_type === 'cron' ? task.cron_expression : `One-shot @ ${formatDate(task.run_at)}`;
}

function edit(task) {
  router.push(`/scheduler/${task.id}/edit`);
}

async function runNow(task) {
  runningNowId.value = task.id;
  try {
    await store.runNow(task.id);
  } finally {
    runningNowId.value = null;
  }
}

function askDelete(task) {
  pendingDelete.value = task;
}

async function confirmDelete() {
  const task = pendingDelete.value;
  pendingDelete.value = null;
  if (!task) return;
  await store.remove(task.id);
}

async function onExport() {
  await exportTasksFile();
}

async function onImportChange(event) {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  importError.value = '';
  importing.value = true;
  try {
    await importTasksFile(file);
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
      title="Scheduler"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load scheduler tasks.' : null"
      empty-text="No scheduler tasks found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
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
          v-if="auth.can(PERMISSIONS.SCHEDULER_CREATE)"
          class="flex cursor-pointer items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconUpload class="h-4 w-4" />
          {{ importing ? 'Importing...' : 'Import' }}
          <input type="file" class="hidden" :disabled="importing" @change="onImportChange" />
        </label>
        <button
          v-if="auth.can(PERMISSIONS.SCHEDULER_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.SCHEDULER_CREATE)"
          to="/scheduler/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Task
        </RouterLink>
      </template>

      <template #messages>
        <p v-if="importError" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ importError }}</p>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Task definitions a "scheduler"-role worker evaluates periodically - cron-recurring or
          one-shot - generating observe/analyze/notify/deliver work for the matching "observer"/
          "analyzer"/"evaluator"/"deliver"-role workers to pick up ahead of
          the normal queue.
        </p>
      </template>

      <template #cell-type="{ value }">
        <span class="capitalize">{{ value }}</span>
      </template>
      <template #cell-observable_type_id="{ value }">{{ observableTypeLabel(value) }}</template>
      <template #cell-target="{ item: task }">{{ targetSummary(task) }}</template>
      <template #cell-schedule="{ item: task }">
        <span class="font-mono text-xs">{{ scheduleSummary(task) }}</span>
      </template>

      <template #cell-enabled="{ item: task }">
        <EnabledBadge :enabled="task.enabled" />
      </template>

      <template #cell-next_run_at="{ value }">{{ value ? formatDate(value) : '—' }}</template>
      <template #cell-last_run_at="{ value }">{{ value ? formatDate(value) : 'Never' }}</template>
      <template #cell-created_at="{ value }">{{ formatDate(value) }}</template>

      <template #row-actions="{ item: task }">
        <button
          type="button"
          title="View details"
          aria-label="View scheduler task details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(task)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.SCHEDULER_UPDATE)"
          type="button"
          title="Run now"
          aria-label="Run scheduler task now"
          :disabled="runningNowId === task.id"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 disabled:opacity-50 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="runNow(task)"
        >
          <IconTrigger class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.SCHEDULER_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit scheduler task"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(task)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.SCHEDULER_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete scheduler task"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(task)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingDelete"
      title="Delete scheduler task"
      :message="pendingDelete ? `Delete scheduler task '${pendingDelete.name}'?` : ''"
      confirm-label="Delete"
      @confirm="confirmDelete"
      @cancel="pendingDelete = null"
    />

    <SchedulerTaskDetailsFlyout :task-id="detailsTaskId" @close="closeDetails" />
  </div>
</template>
