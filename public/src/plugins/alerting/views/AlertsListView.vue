<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlertsStore } from '../../../stores/alerts';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import AlertSeverityBadge from '../../../components/AlertSeverityBadge.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import AlertDetailsFlyout from '../../../components/AlertDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportAlertsFile } from '../../../services/api/alerts';
import { formatDate } from '../../../utils/date';
import { observableTypeLabel } from '../../../utils/observableType';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useAlertsStore();
const observableTypesStore = useObservableTypesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const pendingAction = ref(null); // { type: 'delete', alert } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const exportFormat = ref('json');

const columns = [
  { key: 'id', label: 'ID', sortable: true },
  { key: 'severity', label: 'Severity', sortable: true, sortField: 'severity_value' },
  { key: 'source', label: 'Source', sortable: true },
  { key: 'type', label: 'Type' },
  { key: 'rule_name', label: 'Matched rule' },
  { key: 'tags', label: 'Tags' },
  { key: 'created_at', label: 'Created', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'observation_id', label: 'Observation' },
];

const otherFields = computed(() => [
  {
    key: 'severity',
    label: 'Severity',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'low', label: 'Low' },
      { value: 'medium', label: 'Medium' },
      { value: 'high', label: 'High' },
      { value: 'critical', label: 'Critical' },
    ],
  },
  { key: 'source', label: 'Source', type: 'text' },
  {
    key: 'observable_type_id',
    label: 'Observable type',
    type: 'select',
    options: [{ value: '', label: 'All types' }, ...observableTypesStore.items.map((t) => ({ value: String(t.id), label: t.label || t.name }))],
  },
  { key: 'tags', label: 'Tag', type: 'text', placeholder: 'single tag', title: 'Matches a single tag exactly' },
  {
    key: 'rule_id',
    label: 'Rule',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'matched', label: 'Matched a rule' },
      { value: 'none', label: 'No rule assigned' },
    ],
  },
]);

const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsAlertId = computed(() => route.query.details || null);

function viewDetails(alert) {
  router.push({ query: { ...route.query, details: alert.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function viewObservation(alert) {
  router.push({ path: '/observations', query: { id: alert.observation_id } });
}

function askDelete(alert) {
  pendingAction.value = { type: 'delete', alert };
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
    await store.remove(action.alert.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportAlertsFile(store.buildExportQuery({ format: exportFormat.value }));
}
</script>

<template>
  <div>
    <DataTable
      title="Alerts"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load alerts.' : null"
      empty-text="No alerts found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.ALERTS_DELETE)"
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
          v-if="auth.can(PERMISSIONS.ALERTS_READ)"
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
          Alerts fired by rule matches against ingested observations.
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

      <template #cell-severity="{ item: alert }">
        <AlertSeverityBadge :severity="alert.severity" />
      </template>

      <template #cell-type="{ item: alert }">
        {{ observableTypeLabel(alert.observable_type_id, observableTypesStore.items) }}
      </template>

      <template #cell-rule_name="{ item: alert }">
        <RouterLink
          v-if="alert.rule_id && auth.can(PERMISSIONS.RULES_READ)"
          :to="`/rules/${alert.rule_id}/edit`"
          class="underline hover:text-slate-700 dark:hover:text-slate-200"
        >
          {{ alert.rule_name }}
        </RouterLink>
        <span v-else class="italic text-slate-400 dark:text-slate-500">No rule matched</span>
      </template>

      <template #cell-tags="{ item: alert, filterBy }">
        <button
          v-for="tag in alert.tags || []"
          :key="tag"
          type="button"
          title="Filter by this tag"
          class="mr-1 inline-block cursor-pointer rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
          @click="filterBy('tags', tag)"
        >
          {{ tag }}
        </button>
      </template>

      <template #cell-created_at="{ item: alert }">{{ formatDate(alert.created_at) }}</template>

      <template #cell-observation_id="{ item: alert }">
        <button
          v-if="alert.observation_id && auth.can(PERMISSIONS.OBSERVATIONS_READ)"
          type="button"
          title="View triggering observation"
          class="rounded px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewObservation(alert)"
        >
          Observation #{{ alert.observation_id }}
        </button>
        <span v-else class="text-xs text-slate-400 dark:text-slate-500">—</span>
      </template>

      <template #row-actions="{ item: alert }">
        <button
          type="button"
          title="View details"
          aria-label="View alert details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(alert)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.ALERTS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete alert"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(alert)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete alerts' : 'Delete alert'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected alerts? This cannot be undone.`
            : `Delete alert #${pendingAction.alert.id}?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <AlertDetailsFlyout :alert-id="detailsAlertId" @close="closeDetails" />
  </div>
</template>
