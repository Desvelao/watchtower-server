<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useDeliveriesStore } from '../../../stores/deliveries';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import AlertSeverityBadge from '../../../components/AlertSeverityBadge.vue';
import AlertStatusBadge from '../../../components/AlertStatusBadge.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportDeliveriesFile } from '../../../services/api/alert_deliveries';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useDeliveriesStore();
const router = useRouter();
const channelsStore = useNotificationChannelsStore();
const auth = useAuthStore();
const exportFormat = ref('json');

if (!channelsStore.items.length) channelsStore.fetchList();

// alert_deliveries has a composite (alert_id, channel_id) primary key, not
// a single `id` column - DataTable keys each row by item[idKey] (default
// "id"), so a synthetic one is added here rather than changing DataTable
// itself for one composite-key resource.
const tableItems = computed(() =>
  store.items.map((delivery) => ({ ...delivery, id: `${delivery.alert_id}:${delivery.channel_id}` })),
);

const columns = [
  { key: 'alert_id', label: 'Alert' },
  { key: 'channel_name', label: 'Channel', sortable: true },
  { key: 'channel_type', label: 'Type' },
  { key: 'alert_severity', label: 'Severity' },
  { key: 'rule_name', label: 'Rule' },
  { key: 'status', label: 'Status', sortable: true },
  { key: 'notified_at', label: 'Notified at', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'worker_id', label: 'Worker' },
  { key: 'updated_at', label: 'Updated', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
];

const otherFields = computed(() => [
  {
    key: 'channel_id',
    label: 'Channel',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      ...channelsStore.items.map((c) => ({ value: String(c.id), label: c.name })),
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
      { value: 'sent', label: 'Sent' },
      { value: 'error', label: 'Error' },
    ],
  },
]);

const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'notified_after', toKey: 'notified_before', label: 'Notified' };

const { onFilterUpdate } = useFilterRouteSync(store);

function viewAlert(delivery) {
  router.push({ path: '/alerts', query: { details: delivery.alert_id } });
}

async function onExport() {
  await exportDeliveriesFile(store.buildExportQuery({ format: exportFormat.value }));
}
</script>

<template>
  <div>
    <DataTable
      title="Notification Deliveries"
      :columns="columns"
      :items="tableItems"
      :loading="store.loading"
      :error="store.error ? 'Failed to load notification deliveries.' : null"
      empty-text="No notification deliveries found."
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
        <select
          v-model="exportFormat"
          class="rounded border border-slate-300 px-2 py-1.5 text-sm text-slate-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-300"
        >
          <option value="json">JSON</option>
          <option value="csv">CSV</option>
        </select>
        <button
          v-if="auth.can(PERMISSIONS.DELIVERIES_READ)"
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
          One row per (alert, channel) enqueued by the evaluator role and
          drained by the deliver role - pending means not yet claimed for sending, triggering means
          a deliver worker has claimed it and is sending now.
        </p>
      </template>

      <template #cell-alert_id="{ item: delivery }">#{{ delivery.alert_id }}</template>

      <template #cell-alert_severity="{ item: delivery }">
        <AlertSeverityBadge :severity="delivery.alert_severity" />
      </template>

      <template #cell-status="{ item: delivery }">
        <span :title="delivery.error_message || ''">
          <AlertStatusBadge :status="delivery.status" />
        </span>
      </template>

      <template #cell-rule_name="{ item: delivery }">{{ delivery.rule_name || '—' }}</template>

      <template #cell-notified_at="{ item: delivery }">{{ formatDate(delivery.notified_at) }}</template>
      <template #cell-updated_at="{ item: delivery }">{{ formatDate(delivery.updated_at) }}</template>

      <template #cell-worker_id="{ item: delivery }">{{ delivery.worker_id || '—' }}</template>

      <template #row-actions="{ item: delivery }">
        <button
          type="button"
          title="View alert"
          aria-label="View alert details"
          class="rounded px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewAlert(delivery)"
        >
          View alert
        </button>
      </template>
    </DataTable>
  </div>
</template>
