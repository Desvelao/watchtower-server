<script setup>
import { useRouter } from 'vue-router';
import { useJobsStore } from '../../../stores/jobs';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import AlertStatusBadge from '../../../components/AlertStatusBadge.vue';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useJobsStore();
const auth = useAuthStore();
const router = useRouter();

const columns = [
  { key: 'id', label: 'ID' },
  { key: 'type', label: 'Type' },
  { key: 'ref_id', label: 'Ref' },
  { key: 'monitor_id', label: 'Monitor' },
  { key: 'status', label: 'Status', sortable: true },
  { key: 'action', label: 'Action', class: 'text-xs text-slate-600 dark:text-slate-400' },
  { key: 'message', label: 'Message', class: 'text-xs text-slate-600 dark:text-slate-400' },
  { key: 'retries', label: 'Retries' },
  { key: 'taken_at', label: 'Taken at', class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'acked_at', label: 'Acked at', class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
  { key: 'error_at', label: 'Last error', class: 'whitespace-nowrap' },
];

const otherFields = [
  { key: 'monitor_id', label: 'Monitor', type: 'text' },
  { key: 'ref_id', label: 'Ref ID', type: 'text' },
  {
    key: 'type',
    label: 'Type',
    type: 'select',
    options: [
      { value: '', label: 'Any' },
      { value: 'scrape', label: 'Scrape' },
      { value: 'notify', label: 'Notify' },
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
];

const searchField = { key: 'search', label: 'Search' };

// Deep-links a filter (e.g. a "Monitor" link elsewhere in the app) via
// matching query params.
const { onFilterUpdate } = useFilterRouteSync(store);

function viewMonitor(job) {
  router.push(`/monitors/${job.monitor_id}`);
}
</script>

<template>
  <div>
    <DataTable
      title="Jobs"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load jobs.' : null"
      empty-text="No jobs found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :filters="store.filters"
      :pagination="store.pagination"
      :total-items="store.totalItems"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
      @update:from="store.setPage"
      @update:size="store.setPageSize"
    >
      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          One row per (monitor, type, ref) work assignment a monitor has reported on - status,
          timestamps, and any error recorded along the way.
        </p>
      </template>

      <template #cell-status="{ item: job }">
        <AlertStatusBadge :status="job.status" />
      </template>

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
          v-if="auth.can(PERMISSIONS.MONITORS_READ)"
          type="button"
          title="View monitor"
          class="rounded px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewMonitor(job)"
        >
          {{ job.monitor_id }}
        </button>
      </template>
    </DataTable>
  </div>
</template>
