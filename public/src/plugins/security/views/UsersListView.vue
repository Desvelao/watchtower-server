<script setup>
import { computed, onMounted, ref } from "vue";
import { useRouter } from "vue-router";
import { useUsersStore } from "../../../stores/users";
import { useRolesStore } from "../../../stores/roles";
import { useAuthStore } from "../../../stores/auth";
import { exportUsers } from "../../../services/api/users";
import { HTTPError } from "../../../services/api/http";
import { downloadBlob } from "../../../utils/download";
import DataTable from "../../../components/common/DataTable.vue";
import ConfirmDialog from "../../../components/common/ConfirmDialog.vue";
import EnabledBadge from "../../../components/common/EnabledBadge.vue";
import UserImportDialog from "../components/UserImportDialog.vue";
import IconEdit from "../../../components/common/icons/IconEdit.vue";
import IconDelete from "../../../components/common/icons/IconDelete.vue";
import IconDownload from "../../../components/common/icons/IconDownload.vue";
import IconUpload from "../../../components/common/icons/IconUpload.vue";
import { formatDate } from "../../../utils/date";
import { useFilterRouteSync } from "../../../composables/useFilterRouteSync";
import { PERMISSIONS } from "../../../constants/permissions";

const store = useUsersStore();
const rolesStore = useRolesStore();
const auth = useAuthStore();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', user } | { type: 'bulk-delete', ids }
const bulkError = ref("");
const importOpen = ref(false);

onMounted(() => {
  if (!rolesStore.items.length) rolesStore.fetchList();
});

const roleNameById = computed(() => {
  const map = new Map();
  for (const role of rolesStore.items) map.set(role.id, role.name);
  return map;
});

const columns = [
  { key: "username", label: "Username", sortable: true, class: "font-medium" },
  { key: "role_id", label: "Role" },
  { key: "enabled", label: "Status" },
  { key: "created_at", label: "Created", class: "whitespace-nowrap text-slate-500 dark:text-slate-400" },
];

const otherFields = computed(() => [
  { key: "username", label: "Username", type: "text" },
  {
    key: "role_id",
    label: "Role",
    type: "select",
    options: [
      { value: "", label: "Any" },
      ...rolesStore.items.map((role) => ({ value: String(role.id), label: role.name })),
    ],
  },
  {
    key: "enabled",
    label: "Status",
    type: "select",
    options: [
      { value: "", label: "Any" },
      { value: "true", label: "Enabled" },
      { value: "false", label: "Disabled" },
    ],
  },
]);

const searchField = { key: "search", label: "Search" };
const dateRangeField = { fromKey: "created_after", toKey: "created_before", label: "Created" };

const { onFilterUpdate } = useFilterRouteSync(store);

function edit(user) {
  router.push(`/users/${user.id}/edit`);
}

function askDelete(user) {
  pendingAction.value = { type: "delete", user };
}

function askBulkDelete(ids) {
  pendingAction.value = { type: "bulk-delete", ids: [...ids] };
}

async function exportAndDownload(ids) {
  bulkError.value = "";
  try {
    const { content, contentType } = await exportUsers(ids);
    const isZip = contentType.includes("zip");
    const body = isZip ? content : JSON.stringify(content, null, 2);
    downloadBlob(body, isZip ? "users-export.zip" : "users-export.json", isZip ? "application/zip" : "application/json");
  } catch (err) {
    bulkError.value = err instanceof HTTPError ? err.response.body?.message || "Failed to export users." : "Failed to export users.";
  }
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = "";
  if (action.type === "delete") {
    await store.remove(action.user.id);
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
      title="Users"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load users.' : null"
      empty-text="No users found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :date-range="dateRangeField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.USERS_DELETE)"
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
          v-if="auth.can(PERMISSIONS.USERS_CREATE)"
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
          v-if="auth.can(PERMISSIONS.USERS_CREATE)"
          to="/users/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New User
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Accounts that can sign in to the API, each assigned a single
          <RouterLink to="/roles" class="underline">role</RouterLink>
          that determines their permissions - disabling a user or changing their role takes
          effect immediately, with no re-login required.
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

      <template #cell-role_id="{ item: user }">
        {{ roleNameById.get(user.role_id) || "-" }}
      </template>

      <template #cell-enabled="{ item: user }">
        <EnabledBadge :enabled="user.enabled" />
      </template>

      <template #cell-created_at="{ item: user }">{{ formatDate(user.created_at) }}</template>

      <template #row-actions="{ item: user }">
        <button
          v-if="auth.can(PERMISSIONS.USERS_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit user"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(user)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          type="button"
          title="Export"
          aria-label="Export user"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="exportAndDownload([user.id])"
        >
          <IconDownload class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.USERS_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete user"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(user)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete users' : 'Delete user'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected users? This cannot be undone.`
            : `Delete user '${pendingAction.user.username}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <UserImportDialog
      :open="importOpen"
      @close="importOpen = false"
      @imported="store.fetchList()"
    />
  </div>
</template>
