<script setup>
import { ref, reactive, computed, onMounted } from "vue";
import { useAuthStore } from "../../../stores/auth";
import { listApiKeys, createApiKey, updateApiKey, revokeApiKey, deleteApiKey } from "../../../services/api/auth";
import { HTTPError } from "../../../services/api/http";
import { formatDate, isRelativeDateKeyword, localDateTimeToServerParam } from "../../../utils/date";
import DataTable from "../../../components/common/DataTable.vue";
import ConfirmDialog from "../../../components/common/ConfirmDialog.vue";
import PermissionPicker from "../../../components/common/PermissionPicker.vue";
import IconRevoke from "../../../components/common/icons/IconRevoke.vue";
import IconDelete from "../../../components/common/icons/IconDelete.vue";
import IconEdit from "../../../components/common/icons/IconEdit.vue";
import { PERMISSIONS } from "../../../constants/permissions";
import { WORKER_ROLE_PERMISSIONS } from "../../../constants/workerRolePermissions";
import { WORKER_ROLES } from "../../workers/workerRoleSchemas";

const auth = useAuthStore();

const ROLE_LABELS = {
  observer: "Observer",
  analyzer: "Analyzer",
  evaluator: "Evaluator",
  deliver: "Deliver",
  scheduler: "Scheduler",
};

// The union of every worker role's own minimal permission set - a worker can
// declare more than one role at once (see WORKER_ROLES), so this is what a
// single API key needs to operate as all five simultaneously.
const COMPOSED_PERMISSIONS = [...new Set(WORKER_ROLES.flatMap((role) => WORKER_ROLE_PERMISSIONS[role]))];

const columns = [
  { key: "label", label: "Label" },
  { key: "kid", label: "Key ID", class: "font-mono text-xs" },
  { key: "permissions", label: "Permissions", class: "text-xs text-slate-600 dark:text-slate-400" },
  { key: "created_at", label: "Created", class: "whitespace-nowrap text-slate-500 dark:text-slate-400" },
  { key: "expires_at", label: "Expires", class: "whitespace-nowrap text-slate-500 dark:text-slate-400" },
  { key: "status", label: "Status" },
];

const otherFields = [
  {
    key: "status",
    label: "Status",
    type: "select",
    options: [
      { value: "", label: "Any" },
      { value: "active", label: "Active" },
      { value: "revoked", label: "Revoked" },
    ],
  },
  { key: "permissions", label: "Permissions", type: "text", placeholder: "e.g. alerts:read" },
];

const searchField = { key: "search", label: "Search" };
const dateRangeField = { fromKey: "created_after", toKey: "created_before", label: "Created" };

const filters = reactive({
  search: "",
  status: "",
  permissions: "",
  created_after: "",
  created_before: "",
});

const keys = ref([]);
const totalItems = ref(0);
const pagination = ref({ from: 0, size: 10 });
const loading = ref(true);
const newKey = ref("");
const newLabel = ref("");
const newPermissions = ref([...auth.permissions]);
const newExpiresInDays = ref("");
const copied = ref(false);
const creating = ref(false);
const error = ref("");
const bulkError = ref("");
const editingKid = ref(null);
const editLabelValue = ref("");
const saving = ref(false);
// { type: 'revoke' | 'delete', entry } | { type: 'bulk-revoke' | 'bulk-delete', kids }
const pendingAction = ref(null);

function canUseRolePreset(role) {
  return WORKER_ROLE_PERMISSIONS[role].every((p) => auth.permissions.includes(p));
}

function useRolePreset(role) {
  newPermissions.value = [...WORKER_ROLE_PERMISSIONS[role]];
}

const canUseComposedPreset = computed(() =>
  COMPOSED_PERMISSIONS.every((p) => auth.permissions.includes(p))
);

function useComposedPreset() {
  newPermissions.value = [...COMPOSED_PERMISSIONS];
}

function resolveDateParam(value) {
  if (!value) return undefined;
  return isRelativeDateKeyword(value) ? value : localDateTimeToServerParam(value);
}

function buildQuery() {
  return {
    ...filters,
    created_after: resolveDateParam(filters.created_after),
    created_before: resolveDateParam(filters.created_before),
    ...pagination.value,
  };
}

async function refresh() {
  loading.value = true;
  try {
    const { items, total_items } = await listApiKeys(buildQuery());
    keys.value = items || [];
    totalItems.value = total_items || 0;

    // if the current page came back empty because the last item on the
    // last page was just deleted, step back one page and try again
    if (keys.value.length === 0 && pagination.value.from > 0) {
      pagination.value.from = Math.max(0, pagination.value.from - pagination.value.size);
      await refresh();
    }
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || "Failed to load keys" : "Failed to load keys";
  } finally {
    loading.value = false;
  }
}

onMounted(refresh);

function setPage(from) {
  pagination.value.from = from;
  refresh();
}

function setPageSize(size) {
  pagination.value.size = size;
  pagination.value.from = 0;
  refresh();
}

function onFilterUpdate(patch) {
  Object.assign(filters, patch);
  pagination.value.from = 0;
  refresh();
}

async function onCreate() {
  const label = newLabel.value.trim();
  if (!label) return;

  error.value = "";
  creating.value = true;
  copied.value = false;
  try {
    const expiresInDays = newExpiresInDays.value ? Number(newExpiresInDays.value) : undefined;
    const { api_key } = await createApiKey(label, newPermissions.value, expiresInDays);
    newKey.value = api_key;
    newLabel.value = "";
    newPermissions.value = [...auth.permissions];
    newExpiresInDays.value = "";
    pagination.value.from = 0;
    await refresh();
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || "Failed to create key" : "Failed to create key";
  } finally {
    creating.value = false;
  }
}

function startEdit(entry) {
  editingKid.value = entry.kid;
  editLabelValue.value = entry.label;
}

function cancelEdit() {
  editingKid.value = null;
  editLabelValue.value = "";
}

async function saveEdit(entry) {
  const label = editLabelValue.value.trim();
  if (!label) return;

  error.value = "";
  saving.value = true;
  try {
    await updateApiKey(entry.kid, label);
    entry.label = label;
    editingKid.value = null;
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || "Failed to update key" : "Failed to update key";
  } finally {
    saving.value = false;
  }
}

async function copyKey() {
  try {
    await navigator.clipboard.writeText(newKey.value);
    copied.value = true;
  } catch {
    copied.value = false;
  }
}

function revocableCount(selectedIds) {
  return keys.value.filter((k) => selectedIds.has(k.kid) && !k.revoked).length;
}

function askRevoke(entry) {
  pendingAction.value = { type: "revoke", entry };
}

function askDelete(entry) {
  pendingAction.value = { type: "delete", entry };
}

function askBulkRevoke(selectedIds) {
  const kids = keys.value.filter((k) => selectedIds.has(k.kid) && !k.revoked).map((k) => k.kid);
  pendingAction.value = { type: "bulk-revoke", kids };
}

function askBulkDelete(selectedIds) {
  pendingAction.value = { type: "bulk-delete", kids: [...selectedIds] };
}

async function bulkRevoke(kids) {
  const results = await Promise.allSettled(kids.map((kid) => revokeApiKey(kid)));
  await refresh();
  return results.filter((r) => r.status === "rejected").length;
}

async function bulkDelete(kids) {
  const results = await Promise.allSettled(kids.map((kid) => deleteApiKey(kid)));
  await refresh();
  return results.filter((r) => r.status === "rejected").length;
}

const dialogText = computed(() => {
  const action = pendingAction.value;
  if (!action) return { title: "", message: "", confirmLabel: "Confirm" };

  switch (action.type) {
    case "delete":
      return {
        title: "Delete API key",
        message: `Permanently delete key ${action.entry.kid}? This cannot be undone.`,
        confirmLabel: "Delete",
      };
    case "revoke":
      return {
        title: "Revoke API key",
        message: `Revoke key ${action.entry.kid}? This cannot be undone.`,
        confirmLabel: "Revoke",
      };
    case "bulk-delete":
      return {
        title: "Delete API keys",
        message: `Permanently delete ${action.kids.length} selected API keys? This cannot be undone.`,
        confirmLabel: "Delete",
      };
    case "bulk-revoke":
      return {
        title: "Revoke API keys",
        message: `Revoke ${action.kids.length} selected API keys? This cannot be undone.`,
        confirmLabel: "Revoke",
      };
    default:
      return { title: "", message: "", confirmLabel: "Confirm" };
  }
});

async function confirmPendingAction() {
  const action = pendingAction.value;
  pendingAction.value = null;
  if (!action) return;

  bulkError.value = "";

  if (action.type === "bulk-revoke" || action.type === "bulk-delete") {
    const total = action.kids.length;
    const failed =
      action.type === "bulk-revoke" ? await bulkRevoke(action.kids) : await bulkDelete(action.kids);
    if (failed > 0) {
      bulkError.value = `${total - failed} of ${total} succeeded.`;
    }
    return;
  }

  try {
    if (action.type === "revoke") {
      await revokeApiKey(action.entry.kid);
    } else {
      await deleteApiKey(action.entry.kid);
    }
    await refresh();
  } catch (err) {
    const fallback = action.type === "revoke" ? "Failed to revoke key" : "Failed to delete key";
    error.value = err instanceof HTTPError ? err.response.body?.message || fallback : fallback;
  }
}
</script>

<template>
  <div>
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">API Keys</h1>
    <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
      API keys scoped to specific permissions, used by dispatcher workers and other integrations to
      authenticate against the API.
    </p>

    <div v-if="auth.can(PERMISSIONS.API_KEY_MANAGE)" class="mt-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800">
      <form class="space-y-3" @submit.prevent="onCreate">
        <div class="flex items-end gap-2">
          <div>
            <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">Label *</label>
            <input
              v-model="newLabel"
              type="text"
              required
              placeholder="e.g. CI deploy key"
              class="mt-1 w-56 rounded border border-slate-300 px-3 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">Expires</label>
            <select
              v-model="newExpiresInDays"
              class="mt-1 rounded border border-slate-300 px-3 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
            >
              <option value="">Never</option>
              <option value="7">7 days</option>
              <option value="30">30 days</option>
              <option value="90">90 days</option>
              <option value="365">1 year</option>
            </select>
          </div>
          <button
            type="submit"
            :disabled="creating || !newLabel.trim()"
            class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
          >
            {{ creating ? "Creating..." : "Create API Key" }}
          </button>
        </div>

        <div v-if="auth.permissions.length">
          <div class="flex items-center justify-between">
            <span class="block text-sm font-medium text-slate-700 dark:text-slate-300">Permissions</span>
            <div class="flex flex-wrap justify-end gap-1.5">
              <button
                v-for="role in WORKER_ROLES"
                :key="role"
                type="button"
                :disabled="!canUseRolePreset(role)"
                :title="
                  canUseRolePreset(role)
                    ? `Select only the permissions the ${role} role needs: ${WORKER_ROLE_PERMISSIONS[role].join(', ')}`
                    : `Requires ${WORKER_ROLE_PERMISSIONS[role].join(' and ')}, which you do not currently have`
                "
                class="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
                @click="useRolePreset(role)"
              >
                {{ ROLE_LABELS[role] }}
              </button>
              <button
                type="button"
                :disabled="!canUseComposedPreset"
                :title="
                  canUseComposedPreset
                    ? `Select the union of every worker role's permissions: ${COMPOSED_PERMISSIONS.join(', ')}`
                    : `Requires ${COMPOSED_PERMISSIONS.join(' and ')}, which you do not currently have`
                "
                class="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
                @click="useComposedPreset"
              >
                Composed
              </button>
            </div>
          </div>
          <p class="mt-0.5 text-xs text-slate-500 dark:text-slate-400">
            Only your own current permissions can be granted to a key.
          </p>
          <div class="mt-1.5">
            <PermissionPicker v-model="newPermissions" :available-permissions="auth.permissions" />
          </div>
        </div>
      </form>

      <div v-if="newKey" class="mt-4 rounded border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-900/30">
        <p class="text-xs font-medium text-amber-800 dark:text-amber-300">
          Copy this key now - it will not be shown again.
        </p>
        <div class="mt-2 flex items-center gap-2">
          <code class="flex-1 overflow-x-auto rounded bg-white px-2 py-1 text-xs dark:bg-slate-900 dark:text-slate-100">{{ newKey }}</code>
          <button
            type="button"
            class="rounded border border-amber-400 px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-100 dark:border-amber-600 dark:text-amber-300 dark:hover:bg-amber-900/40"
            @click="copyKey"
          >
            {{ copied ? "Copied!" : "Copy" }}
          </button>
        </div>
      </div>
    </div>

    <p v-if="error" class="mt-3 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <div class="mt-6">
      <DataTable
        :columns="columns"
        :items="keys"
        id-key="kid"
        :loading="loading"
        empty-text="No API keys yet."
        :other-fields="otherFields"
        :search="searchField"
        :date-range="dateRangeField"
        :filters="filters"
        :selectable="auth.can(PERMISSIONS.API_KEY_MANAGE)"
        :pagination="totalItems > 0 ? pagination : null"
        :total-items="totalItems"
        @refresh="refresh"
        @update:filters="onFilterUpdate"
        @update:from="setPage"
        @update:size="setPageSize"
      >
        <template #title>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">Your API keys</h2>
        </template>

        <template #messages>
          <p v-if="bulkError" class="mt-4 text-sm text-amber-700 dark:text-amber-400">{{ bulkError }}</p>
        </template>

        <template #bulk-actions="{ selectedIds }">
          <button
            v-if="revocableCount(selectedIds) > 0"
            type="button"
            class="flex items-center gap-1.5 rounded p-1.5 text-sm font-medium text-amber-600 hover:bg-amber-50 hover:text-amber-800 dark:text-amber-400 dark:hover:bg-amber-900/30 dark:hover:text-amber-300"
            @click="askBulkRevoke(selectedIds)"
          >
            <IconRevoke class="h-4 w-4" />
            Revoke selected
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

        <template #cell-label="{ item: entry }">
          <div v-if="editingKid === entry.kid" class="flex items-center gap-1.5">
            <input
              v-model="editLabelValue"
              type="text"
              required
              class="w-40 rounded border border-slate-300 px-2 py-1 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @keyup.enter="saveEdit(entry)"
              @keyup.escape="cancelEdit"
            />
            <button
              type="button"
              :disabled="saving || !editLabelValue.trim()"
              class="rounded px-1.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:text-slate-300 dark:hover:bg-slate-700"
              @click="saveEdit(entry)"
            >
              Save
            </button>
            <button
              type="button"
              class="rounded px-1.5 py-1 text-xs font-medium text-slate-500 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-700"
              @click="cancelEdit"
            >
              Cancel
            </button>
          </div>
          <div v-else class="flex items-center gap-1.5">
            <span>{{ entry.label }}</span>
            <button
              v-if="auth.can(PERMISSIONS.API_KEY_MANAGE)"
              type="button"
              title="Edit label"
              aria-label="Edit label"
              class="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-700 dark:text-slate-500 dark:hover:bg-slate-700 dark:hover:text-slate-300"
              @click="startEdit(entry)"
            >
              <IconEdit class="h-3.5 w-3.5" />
            </button>
          </div>
        </template>

        <template #cell-permissions="{ item: entry }">
          {{ entry.permissions?.length ? entry.permissions.join(", ") : "—" }}
        </template>

        <template #cell-created_at="{ item: entry }">{{ formatDate(entry.created_at) }}</template>

        <template #cell-expires_at="{ item: entry }">{{ entry.expires_at ? formatDate(entry.expires_at) : "Never" }}</template>

        <template #cell-status="{ item: entry }">
          <span v-if="entry.revoked" class="text-xs text-slate-400 dark:text-slate-500">Revoked</span>
          <span v-else class="text-xs text-green-700 dark:text-green-400">Active</span>
        </template>

        <template #row-actions="{ item: entry }">
          <button
            v-if="!entry.revoked && auth.can(PERMISSIONS.API_KEY_MANAGE)"
            type="button"
            title="Revoke"
            aria-label="Revoke API key"
            class="rounded p-1.5 text-amber-600 hover:bg-amber-50 hover:text-amber-800 dark:text-amber-400 dark:hover:bg-amber-900/30 dark:hover:text-amber-300"
            @click="askRevoke(entry)"
          >
            <IconRevoke class="h-4 w-4" />
          </button>
          <button
            v-if="auth.can(PERMISSIONS.API_KEY_MANAGE)"
            type="button"
            title="Delete"
            aria-label="Delete API key"
            class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
            @click="askDelete(entry)"
          >
            <IconDelete class="h-4 w-4" />
          </button>
        </template>
      </DataTable>
    </div>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="dialogText.title"
      :message="dialogText.message"
      :confirm-label="dialogText.confirmLabel"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />
  </div>
</template>
