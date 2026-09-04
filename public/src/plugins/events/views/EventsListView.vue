<script setup>
import { ref } from "vue";
import { useRouter } from "vue-router";
import { useEventsStore } from "../../../stores/events";
import { useAuthStore } from "../../../stores/auth";
import DataTable from "../../../components/common/DataTable.vue";
import ConfirmDialog from "../../../components/common/ConfirmDialog.vue";
import IconDelete from "../../../components/common/icons/IconDelete.vue";
import { formatDate } from "../../../utils/date";
import { useFilterRouteSync } from "../../../composables/useFilterRouteSync";
import { PERMISSIONS } from "../../../constants/permissions";

const store = useEventsStore();
const auth = useAuthStore();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', event } | { type: 'bulk-delete', ids }
const bulkError = ref("");

const columns = [
  { key: "id", label: "ID", sortable: true },
  { key: "source", label: "Source", sortable: true },
  { key: "payload", label: "Payload" },
  { key: "tags", label: "Tags" },
  { key: "created_at", label: "Created", sortable: true, class: "whitespace-nowrap text-slate-500 dark:text-slate-400" },
];

const otherFields = [
  { key: "source", label: "Source", type: "text" },
  { key: "tags", label: "Tag", type: "text", placeholder: "single tag", title: "Matches a single tag exactly" },
];

const searchField = { key: "search", label: "Search" };
const dateRangeField = { fromKey: "created_after", toKey: "created_before", label: "Created" };

const { onFilterUpdate } = useFilterRouteSync(store);

function viewAlerts(event) {
  router.push({ path: '/alerts', query: { event_id: event.id } });
}

function askDelete(event) {
  pendingAction.value = { type: "delete", event };
}

function askBulkDelete(ids) {
  pendingAction.value = { type: "bulk-delete", ids: [...ids] };
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = "";
  if (action.type === "delete") {
    await store.remove(action.event.id);
  } else if (action.type === "bulk-delete") {
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
      title="Events"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load events.' : null"
      empty-text="No events found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.EVENTS_DELETE)"
      :pagination="store.pagination"
      :total-items="store.totalItems"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
      @update:from="store.setPage"
      @update:size="store.setPageSize"
    >
      <template #header-actions>
        <RouterLink
          v-if="auth.can(PERMISSIONS.EVENTS_CREATE)"
          to="/events/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Event
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Raw ingested data. Creating an event is the only way an alert enters the system - each row
          here resolved a rule match (or didn't) and produced the linked alert as a side effect.
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

      <template #cell-payload="{ item: event }">{{ event.payload || "-" }}</template>

      <template #cell-tags="{ item: event, filterBy }">
        <button
          v-for="tag in event.tags || []"
          :key="tag"
          type="button"
          title="Filter by this tag"
          class="mr-1 inline-block cursor-pointer rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
          @click="filterBy('tags', tag)"
        >
          {{ tag }}
        </button>
      </template>

      <template #cell-created_at="{ item: event }">{{ formatDate(event.created_at) }}</template>

      <template #row-actions="{ item: event }">
        <button
          v-if="event.alert_count > 0 && auth.can(PERMISSIONS.ALERTS_READ)"
          type="button"
          title="View resulting alert(s)"
          class="rounded px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewAlerts(event)"
        >
          {{ event.alert_count > 1 ? `Alerts (${event.alert_count})` : "Alert" }}
        </button>
        <button
          v-if="auth.can(PERMISSIONS.EVENTS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete event"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(event)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete events' : 'Delete event'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected events? This also deletes their alerts and cannot be undone.`
            : `Delete event #${pendingAction.event.id}${pendingAction.event.payload ? ` (${pendingAction.event.payload})` : ''}? This also deletes its alert.`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />
  </div>
</template>
