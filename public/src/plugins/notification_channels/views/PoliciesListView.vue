<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useNotificationPoliciesStore } from '../../../stores/notificationPolicies';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import EnabledBadge from '../../../components/common/EnabledBadge.vue';
import PolicyDetailsFlyout from '../components/PolicyDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import PolicyImportDialog from '../components/PolicyImportDialog.vue';
import { exportPolicies } from '../../../services/api/notification_policies';
import { HTTPError } from '../../../services/api/http';
import { downloadBlob } from '../../../utils/download';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useNotificationPoliciesStore();
const channelsStore = useNotificationChannelsStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', policy } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const importOpen = ref(false);

const columns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'condition_expression', label: 'Condition' },
  { key: 'channel_ids', label: 'Channels' },
  { key: 'enabled', label: 'Enabled', sortable: true },
  { key: 'created_at', label: 'Created', sortable: true, class: 'whitespace-nowrap text-slate-500 dark:text-slate-400' },
];

const otherFields = computed(() => [
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
const dateRangeField = { fromKey: 'created_after', toKey: 'created_before', label: 'Created' };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsPolicyId = computed(() => route.query.details || null);

function viewDetails(policy) {
  router.push({ query: { ...route.query, details: policy.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function channelName(id) {
  const channel = channelsStore.items.find((c) => c.id === id);
  return channel ? channel.name : `#${id}`;
}

onMounted(() => {
  if (!channelsStore.items.length) channelsStore.fetchList();
});

function edit(policy) {
  router.push(`/notification_policies/${policy.id}/edit`);
}

function askDelete(policy) {
  pendingAction.value = { type: 'delete', policy };
}

function askBulkDelete(ids) {
  pendingAction.value = { type: 'bulk-delete', ids: [...ids] };
}

async function exportAndDownload(ids) {
  bulkError.value = '';
  try {
    const { content, contentType } = await exportPolicies(ids);
    const isZip = contentType.includes('zip');
    downloadBlob(
      content,
      isZip ? 'notification-policies-export.zip' : 'notification-policies-export.yaml',
      isZip ? 'application/zip' : 'text/yaml',
    );
  } catch (err) {
    bulkError.value =
      err instanceof HTTPError ? err.response.body?.message || 'Failed to export notification policies.' : 'Failed to export notification policies.';
  }
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = '';
  if (action.type === 'delete') {
    await store.remove(action.policy.id);
  } else if (action.type === 'bulk-delete') {
    const { total, failed } = await store.bulkRemove(action.ids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} deletions succeeded.`;
    }
  }
}
</script>

<template>
  <div>
    <DataTable
      title="Notification Policies"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load notification policies.' : null"
      empty-text="No notification policies found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.POLICIES_DELETE)"
      :pagination="store.pagination"
      :total-items="store.totalItems"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
      @update:from="store.setPage"
      @update:size="store.setPageSize"
    >
      <template #header-actions>
        <button
          v-if="auth.can(PERMISSIONS.POLICIES_CREATE)"
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="importOpen = true"
        >
          <IconUpload class="h-4 w-4" />
          Import
        </button>
        <button
          type="button"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="exportAndDownload()"
        >
          <IconDownload class="h-4 w-4" />
          Export all
        </button>
        <RouterLink
          v-if="auth.can(PERMISSIONS.POLICIES_CREATE)"
          to="/notification_policies/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Policy
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Routes fired alerts to notification channels via the same condition language rules use to match
          observations - matching against the alert's own fields (severity/tags/rule_id/observable_id).
          Evaluated by a scheduler task of type "notify".
        </p>
      </template>

      <template #messages>
        <p v-if="bulkError" class="mt-4 text-sm text-amber-700 dark:text-amber-400">{{ bulkError }}</p>
      </template>

      <template #bulk-actions="{ selectedIds }">
        <button
          type="button"
          class="flex items-center gap-1.5 rounded p-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="exportAndDownload([...selectedIds])"
        >
          <IconDownload class="h-4 w-4" />
          Export selected
        </button>
        <button
          type="button"
          class="flex items-center gap-1.5 rounded p-1.5 text-sm font-medium text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askBulkDelete(selectedIds)"
        >
          <IconDelete class="h-4 w-4" />
          Delete selected
        </button>
      </template>

      <template #cell-condition_expression="{ item: policy }">
        <span class="block max-w-[280px] truncate font-mono text-xs" :title="policy.condition_expression">
          {{ policy.condition_expression }}
        </span>
      </template>

      <template #cell-channel_ids="{ item: policy }">
        <span class="text-xs">{{ (policy.channel_ids || []).map(channelName).join(', ') || '-' }}</span>
      </template>

      <template #cell-enabled="{ item: policy }">
        <EnabledBadge :enabled="policy.enabled" />
      </template>

      <template #cell-created_at="{ item: policy }">{{ formatDate(policy.created_at) }}</template>

      <template #row-actions="{ item: policy }">
        <button
          type="button"
          title="View details"
          aria-label="View notification policy details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(policy)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.POLICIES_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit notification policy"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(policy)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          type="button"
          title="Export"
          aria-label="Export notification policy"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="exportAndDownload([policy.id])"
        >
          <IconDownload class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.POLICIES_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete notification policy"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(policy)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete notification policies' : 'Delete notification policy'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected notification policies? This cannot be undone.`
            : `Delete notification policy '${pendingAction.policy.name}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <PolicyImportDialog
      :open="importOpen"
      @close="importOpen = false"
      @imported="store.fetchList()"
    />

    <PolicyDetailsFlyout :policy-id="detailsPolicyId" @close="closeDetails" />
  </div>
</template>
