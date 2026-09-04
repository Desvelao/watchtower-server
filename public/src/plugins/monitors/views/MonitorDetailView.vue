<script setup>
import { onMounted, ref, reactive, computed, watch } from 'vue';
import { RouterLink } from 'vue-router';
import { listMonitors, getMonitorHeartbeats } from '../../../services/api/monitors';
import { listJobs } from '../../../services/api/jobs';
import { formatDate, formatUptime, parseServerDate } from '../../../utils/date';
import AlertStatusBadge from '../../../components/AlertStatusBadge.vue';
import BarHistogram from '../../../components/common/BarHistogram.vue';
import DataTable from '../../../components/common/DataTable.vue';
import MonitorConfigFlyout from '../../../components/MonitorConfigFlyout.vue';

const props = defineProps({
  id: { type: String, required: true },
});

// --- Monitor info -------------------------------------------------
// No monitors store and no single-monitor-by-id endpoint exists, so this
// page does its own independent listMonitors() fetch and finds the
// matching row client-side - same "fetch full list + find" precedent
// AlertDetailsFlyout.vue already uses for alerts.
const monitor = ref(null);
const monitorLoading = ref(true);
const monitorError = ref('');

async function loadMonitor() {
  monitorLoading.value = true;
  try {
    const { items } = await listMonitors();
    monitor.value = (items || []).find((m) => m.monitor_id === props.id) || null;
    if (!monitor.value) monitorError.value = 'Monitor not found.';
    else monitorError.value = '';
  } catch (err) {
    monitorError.value = 'Failed to load monitor.';
  } finally {
    monitorLoading.value = false;
  }
}

onMounted(loadMonitor);

// Worker-reported config is optional (see shared/worker_config_report.lua /
// report_config) and stored as opaque JSON text - shown via
// MonitorConfigFlyout, which owns the pretty-printing/highlighting.
const showConfigFlyout = ref(false);

// --- Heartbeat histogram ----------------------------------------------
// Connectivity (per-bucket "had a heartbeat or not") is the default view -
// the original count histogram is available behind this toggle.
const showCount = ref(false);
const RANGE_PRESETS = [
  { value: '1h', label: 'Last hour', ms: 60 * 60 * 1000, bucket: 'minute' },
  { value: '24h', label: 'Last 24 hours', ms: 24 * 60 * 60 * 1000, bucket: 'hour' },
  { value: '7d', label: 'Last 7 days', ms: 7 * 24 * 60 * 60 * 1000, bucket: 'hour' },
  { value: '30d', label: 'Last 30 days', ms: 30 * 24 * 60 * 60 * 1000, bucket: 'day' },
];

const selectedRange = ref('24h');
const heartbeatBuckets = ref([]);
const heartbeatLoading = ref(true);
const heartbeatError = ref('');

function truncateUtc(date, unit) {
  const d = new Date(date.getTime());
  if (unit === 'minute') d.setUTCSeconds(0, 0);
  else if (unit === 'hour') d.setUTCMinutes(0, 0, 0);
  else d.setUTCHours(0, 0, 0, 0);
  return d;
}

function stepUtc(date, unit) {
  const d = new Date(date.getTime());
  if (unit === 'minute') d.setUTCMinutes(d.getUTCMinutes() + 1);
  else if (unit === 'hour') d.setUTCHours(d.getUTCHours() + 1);
  else d.setUTCDate(d.getUTCDate() + 1);
  return d;
}

// The server only returns non-empty buckets; fill the gaps so bars stay
// evenly spaced and correctly positioned in time rather than only
// reflecting whichever buckets happened to have data.
function zeroFillBuckets(rawItems, since, until, unit) {
  const counts = new Map();
  for (const item of rawItems) {
    const t = parseServerDate(item.bucket);
    if (t) counts.set(t.getTime(), item.count);
  }
  const result = [];
  let cursor = truncateUtc(since, unit);
  while (cursor <= until) {
    result.push({ time: new Date(cursor), count: counts.get(cursor.getTime()) || 0 });
    cursor = stepUtc(cursor, unit);
  }
  return result;
}

// Sent as bare "YYYY-MM-DDTHH:MM:SS" (no trailing Z) - the server's
// `created_at` column is a naive timestamp meant as UTC wall-clock (same
// convention documented in utils/date.js's parseServerDate), so range
// bounds are sent the same naive way rather than relying on Postgres's
// timestamptz-string-to-timestamp cast behavior under an assumed session
// timezone.
function toNaiveUtcParam(date) {
  return date.toISOString().slice(0, 19);
}

async function loadHeartbeats() {
  const preset = RANGE_PRESETS.find((p) => p.value === selectedRange.value);
  const until = new Date();
  const since = new Date(until.getTime() - preset.ms);

  heartbeatLoading.value = true;
  try {
    const { items } = await getMonitorHeartbeats(props.id, {
      since: toNaiveUtcParam(since),
      until: toNaiveUtcParam(until),
      bucket: preset.bucket,
    });
    heartbeatBuckets.value = zeroFillBuckets(items || [], since, until, preset.bucket);
    heartbeatError.value = '';
  } catch (err) {
    heartbeatError.value = 'Failed to load heartbeat history.';
  } finally {
    heartbeatLoading.value = false;
  }
}

const selectedBucketUnit = computed(
  () => RANGE_PRESETS.find((p) => p.value === selectedRange.value).bucket,
);

onMounted(loadHeartbeats);
watch(selectedRange, loadHeartbeats);

// --- Jobs ----------------------------------------------------
const jobs = ref([]);
const jobsTotal = ref(0);
const jobsLoading = ref(true);
const jobsError = ref('');
const jobFilters = reactive({ type: '', status: '', search: '' });
const jobSort = ref('id:desc');
const pagination = ref({ from: 0, size: 10 });

const jobColumns = [
  { key: 'type', label: 'Type' },
  { key: 'ref_id', label: 'Ref' },
  { key: 'status', label: 'Status', sortable: true },
  { key: 'action', label: 'Action' },
  { key: 'message', label: 'Message' },
  { key: 'taken_at', label: 'Taken at' },
  { key: 'acked_at', label: 'Acked at' },
  { key: 'retries', label: 'Retries' },
  { key: 'error_at', label: 'Last error' },
];

const jobOtherFields = [
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
const jobSearchField = { key: 'search', label: 'Search' };

async function loadJobs() {
  jobsLoading.value = true;
  try {
    const { items, total_items } = await listJobs({
      monitor_id: props.id,
      type: jobFilters.type,
      status: jobFilters.status,
      search: jobFilters.search,
      sort: jobSort.value,
      from: pagination.value.from,
      size: pagination.value.size,
    });
    jobs.value = items || [];
    jobsTotal.value = total_items || 0;
    jobsError.value = '';
  } catch (err) {
    jobsError.value = 'Failed to load jobs.';
  } finally {
    jobsLoading.value = false;
  }
}

onMounted(loadJobs);

function onJobFilterUpdate(patch) {
  Object.assign(jobFilters, patch);
  pagination.value.from = 0;
  loadJobs();
}

function onJobSortUpdate(sort) {
  jobSort.value = sort;
  loadJobs();
}

function onPageChange(from) {
  pagination.value.from = from;
  loadJobs();
}

function onPageSizeChange(size) {
  pagination.value.size = size;
  pagination.value.from = 0;
  loadJobs();
}
</script>

<template>
  <div>
    <RouterLink
      to="/monitors"
      class="text-sm text-slate-500 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"
    >
      ← Monitors
    </RouterLink>

    <h1 class="mt-1 text-xl font-semibold text-slate-900 dark:text-slate-100">{{ id }}</h1>

    <p v-if="monitorLoading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="monitorError" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ monitorError }}</p>

    <template v-else-if="monitor">
      <div class="mt-4 grid grid-cols-1 gap-6 lg:grid-cols-3">
        <section class="lg:col-span-1">
          <h2 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h2>
          <table class="mt-2 w-full text-sm">
            <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
              <tr>
                <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">Connection</td>
                <td class="py-1.5">{{ monitor.connection_type || '—' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Capabilities</td>
                <td class="py-1.5">{{ (monitor.capabilities || []).join(', ') || '—' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Filters items</td>
                <td class="py-1.5">
                  <span v-if="monitor.item_filter" class="font-mono">{{ monitor.item_filter }}</span>
                  <span v-else>All items</span>
                </td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Version</td>
                <td class="py-1.5">{{ monitor.version || '—' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Uptime</td>
                <td class="py-1.5">{{ formatUptime(monitor.uptime_seconds) }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Last seen</td>
                <td class="py-1.5">{{ monitor.last_seen_at ? formatDate(monitor.last_seen_at) : 'Never' }}</td>
              </tr>
              <tr>
                <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Config</td>
                <td class="py-1.5">
                  <button
                    v-if="monitor.config"
                    type="button"
                    class="text-slate-700 underline hover:text-slate-900 dark:text-slate-300 dark:hover:text-slate-100"
                    @click="showConfigFlyout = true"
                  >
                    View config
                  </button>
                  <span v-else>Not reported</span>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="lg:col-span-2">
          <div class="flex items-center justify-between">
            <h2 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
              {{ showCount ? 'Heartbeats' : 'Connectivity' }}
            </h2>
            <div class="flex items-center gap-2">
              <button
                type="button"
                class="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
                @click="showCount = !showCount"
              >
                {{ showCount ? 'Show connectivity' : 'Show heartbeat count' }}
              </button>
              <select
                v-model="selectedRange"
                class="rounded border border-slate-300 px-2 py-1 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              >
                <option v-for="preset in RANGE_PRESETS" :key="preset.value" :value="preset.value">
                  {{ preset.label }}
                </option>
              </select>
            </div>
          </div>

          <p v-if="heartbeatLoading" class="mt-2 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
          <p v-else-if="heartbeatError" class="mt-2 text-sm text-red-600 dark:text-red-400">{{ heartbeatError }}</p>
          <div
            v-else
            class="mt-2 rounded-lg border border-slate-200 bg-white p-3 dark:border-slate-700 dark:bg-slate-800"
          >
            <BarHistogram
              :buckets="heartbeatBuckets"
              :bucket-unit="selectedBucketUnit"
              :variant="showCount ? 'count' : 'connectivity'"
              :aria-label="showCount ? 'Heartbeat count over time' : 'Connectivity over time'"
              :unit-label="showCount ? 'heartbeats' : 'status'"
            />
          </div>
        </section>
      </div>

      <section class="mt-6">
        <DataTable
          title="Jobs"
          :columns="jobColumns"
          :items="jobs"
          :loading="jobsLoading"
          :error="jobsError || null"
          empty-text="No jobs found."
          :sort="jobSort"
          :other-fields="jobOtherFields"
          :search="jobSearchField"
          :filters="jobFilters"
          :pagination="pagination"
          :total-items="jobsTotal"
          @refresh="loadJobs"
          @update:filters="onJobFilterUpdate"
          @update:sort="onJobSortUpdate"
          @update:from="onPageChange"
          @update:size="onPageSizeChange"
        >
          <template #title>
            <h2 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Jobs</h2>
          </template>

          <template #cell-status="{ item: j }"><AlertStatusBadge :status="j.status" /></template>
          <template #cell-action="{ item: j }">{{ j.action || '—' }}</template>
          <template #cell-message="{ item: j }">
            <span class="block max-w-[280px] truncate" :title="j.message || ''">{{ j.message || '—' }}</span>
          </template>
          <template #cell-taken_at="{ item: j }">{{ formatDate(j.taken_at) }}</template>
          <template #cell-acked_at="{ item: j }">{{ formatDate(j.acked_at) }}</template>
          <template #cell-error_at="{ item: j }">
            <span :class="j.error_at ? 'text-red-600 dark:text-red-400' : ''">
              {{ formatDate(j.error_at) }}
            </span>
          </template>
        </DataTable>
      </section>
    </template>

    <MonitorConfigFlyout
      :open="showConfigFlyout"
      :config="monitor?.config"
      :monitor-id="monitor?.monitor_id"
      @close="showConfigFlyout = false"
    />
  </div>
</template>
