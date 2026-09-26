<script setup>
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import NotificationChannelDetailsFlyout from '../components/NotificationChannelDetailsFlyout.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import { exportNotificationChannelsFile, importNotificationChannelsFile } from '../../../services/api/notification_channels';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useNotificationChannelsStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', channel } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const importing = ref(false);
const importError = ref('');

const columns = [
  { key: 'id', label: 'ID', sortable: true },
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'type', label: 'Type' },
  { key: 'created_at', label: 'Created', sortable: true },
  { key: 'updated_at', label: 'Updated', sortable: true },
];

const otherFields = computed(() => [{ key: 'name', label: 'Name', type: 'text' }]);
const searchField = { key: 'search', label: 'Search' };
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsChannelId = computed(() => route.query.details || null);

function viewDetails(channel) {
  router.push({ query: { ...route.query, details: channel.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(channel) {
  router.push(`/notifications_channels/${channel.id}/edit`);
}

function askDelete(channel) {
  pendingAction.value = { type: 'delete', channel };
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
    await store.remove(action.channel.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}

async function onExport() {
  await exportNotificationChannelsFile();
}

async function onImportChange(event) {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  importError.value = '';
  importing.value = true;
  try {
    await importNotificationChannelsFile(file);
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
      title="Notification Channels"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load notification channels.' : null"
      empty-text="No notification channels found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.CHANNELS_DELETE)"
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
          v-if="auth.can(PERMISSIONS.CHANNELS_CREATE)"
          class="flex cursor-pointer items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconUpload class="h-4 w-4" />
          {{ importing ? 'Importing...' : 'Import' }}
          <input type="file" class="hidden" :disabled="importing" @change="onImportChange" />
        </label>
        <button
          v-if="auth.can(PERMISSIONS.CHANNELS_READ)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onExport"
        >
          <IconDownload class="h-4 w-4" />
          Export
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.CHANNELS_CREATE)"
          to="/notifications_channels/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Channel
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

      <template #cell-created_at="{ value }">{{ formatDate(value) }}</template>
      <template #cell-updated_at="{ value }">{{ formatDate(value) }}</template>

      <template #row-actions="{ item: channel }">
        <button
          type="button"
          title="View details"
          aria-label="View channel details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(channel)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.CHANNELS_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit channel"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(channel)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.CHANNELS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete channel"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(channel)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>

    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete channels' : 'Delete channel'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected channels? This cannot be undone.`
            : `Delete channel '${pendingAction.channel.name}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <NotificationChannelDetailsFlyout :channel-id="detailsChannelId" @close="closeDetails" />
  </div>
</template>
