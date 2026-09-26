<script setup>
import { computed, onMounted, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useRolesStore } from "../../../stores/roles";
import { useAuthStore } from "../../../stores/auth";
import { exportRoles } from "../../../services/api/roles";
import { HTTPError } from "../../../services/api/http";
import { downloadBlob } from "../../../utils/download";
import DataTable from "../../../components/common/DataTable.vue";
import ConfirmDialog from "../../../components/common/ConfirmDialog.vue";
import RoleDetailsFlyout from "../components/RoleDetailsFlyout.vue";
import RoleImportDialog from "../components/RoleImportDialog.vue";
import IconEye from "../../../components/common/icons/IconEye.vue";
import IconEdit from "../../../components/common/icons/IconEdit.vue";
import IconDelete from "../../../components/common/icons/IconDelete.vue";
import IconDownload from "../../../components/common/icons/IconDownload.vue";
import IconUpload from "../../../components/common/icons/IconUpload.vue";
import { PERMISSIONS } from "../../../constants/permissions";
import { useFilterRouteSync } from "../../../composables/useFilterRouteSync";

const store = useRolesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', role }
const bulkError = ref("");
const importOpen = ref(false);

onMounted(() => store.fetchList());

const columns = [
  { key: "name", label: "Name", sortable: true, class: "font-medium" },
  { key: "permissions", label: "Permissions", class: "text-xs text-slate-600 dark:text-slate-400" },
];

// The permission catalog is fixed in code (see constants/permissions.js),
// so a select with every known permission is more usable here than free
// text - unlike e.g. Alerts' "Tag" filter, which has no fixed set.
const permissionOptions = [...new Set(Object.values(PERMISSIONS))].sort();

const otherFields = [
  {
    key: "permission",
    label: "Permission",
    type: "select",
    options: [{ value: "", label: "Any" }, ...permissionOptions.map((p) => ({ value: p, label: p }))],
  },
];

const searchField = { key: "search", label: "Search" };

const { onFilterUpdate } = useFilterRouteSync(store, { extraQueryKeys: ['details'] });

const detailsRoleId = computed(() => route.query.details || null);

function viewDetails(role) {
  router.push({ query: { ...route.query, details: role.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(role) {
  router.push(`/roles/${role.id}/edit`);
}

function askDelete(role) {
  pendingAction.value = { type: "delete", role };
}

async function exportAndDownload(ids) {
  bulkError.value = "";
  try {
    const { content, contentType } = await exportRoles(ids);
    const isZip = contentType.includes("zip");
    const body = isZip ? content : JSON.stringify(content, null, 2);
    downloadBlob(body, isZip ? "roles-export.zip" : "roles-export.json", isZip ? "application/zip" : "application/json");
  } catch (err) {
    bulkError.value = err instanceof HTTPError ? err.response.body?.message || "Failed to export roles." : "Failed to export roles.";
  }
}

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = "";
  try {
    await store.remove(action.role.id);
  } catch (err) {
    bulkError.value = err.response?.body?.message || "Failed to delete role.";
  }
}
</script>

<template>
  <div>
    <DataTable
      title="Roles"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load roles.' : null"
      empty-text="No roles found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.ROLES_READ)"
      @refresh="store.fetchList()"
      @update:filters="onFilterUpdate"
      @update:sort="store.setSort"
    >
      <template #header-actions>
        <button
          v-if="auth.can(PERMISSIONS.ROLES_CREATE)"
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
          v-if="auth.can(PERMISSIONS.ROLES_CREATE)"
          to="/roles/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Role
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Each role is a named set of permissions assigned to users - editing a role's permissions
          takes effect immediately for every user currently assigned to it.
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
      </template>

      <template #cell-permissions="{ item: role }">
        <span class="block max-w-[420px] truncate" :title="(role.permissions || []).join(', ')">
          {{ (role.permissions || []).join(", ") || "-" }}
        </span>
      </template>

      <template #row-actions="{ item: role }">
        <button
          type="button"
          title="View details"
          aria-label="View role details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(role)"
        >
          <IconEye class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.ROLES_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit role"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(role)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          type="button"
          title="Export"
          aria-label="Export role"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="exportAndDownload([role.id])"
        >
          <IconDownload class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.ROLES_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete role"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(role)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      title="Delete role"
      :message="pendingAction ? `Delete role '${pendingAction.role.name}'?` : ''"
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />

    <RoleDetailsFlyout :role-id="detailsRoleId" @close="closeDetails" />

    <RoleImportDialog
      :open="importOpen"
      @close="importOpen = false"
      @imported="store.fetchList()"
    />
  </div>
</template>
