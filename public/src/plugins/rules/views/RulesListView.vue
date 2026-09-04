<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useRulesStore } from '../../../stores/rules';
import { useAuthStore } from '../../../stores/auth';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconFlask from '../../../components/common/icons/IconFlask.vue';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useRulesStore();
const auth = useAuthStore();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', rule } | { type: 'bulk-delete', ids }
const bulkError = ref('');

const columns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'action', label: 'Action', sortable: true },
  { key: 'condition_expression', label: 'Condition' },
  { key: 'enabled', label: 'Enabled', sortable: true },
];

const otherFields = computed(() => [
  { key: 'name', label: 'Name', type: 'text' },
  { key: 'action', label: 'Action', type: 'text' },
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

const { onFilterUpdate } = useFilterRouteSync(store);

function edit(rule) {
  router.push(`/rules/${rule.id}/edit`);
}

function askDelete(rule) {
  pendingAction.value = { type: 'delete', rule };
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
    await store.remove(action.rule.id);
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
      title="Rules"
      :columns="columns"
      :items="store.items"
      :loading="store.loading"
      :error="store.error ? 'Failed to load rules.' : null"
      empty-text="No rules found."
      :sort="store.sort"
      :other-fields="otherFields"
      :search="searchField"
      :filters="store.filters"
      :selectable="auth.can(PERMISSIONS.RULES_DELETE)"
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
          v-if="auth.can(PERMISSIONS.RULES_READ)"
          to="/rules/test"
          class="flex items-center gap-1.5 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          <IconFlask class="h-4 w-4" />
          Test Rules
        </RouterLink>
        <RouterLink
          v-if="auth.can(PERMISSIONS.RULES_CREATE)"
          to="/rules/new"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          New Rule
        </RouterLink>
      </template>

      <template #description>
        <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
          Boolean-expression rules evaluated against each incoming event to resolve its dispatch
          action, and optionally override severity or tags.
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

      <template #cell-condition_expression="{ item: rule }">
        <span class="block max-w-[280px] truncate font-mono text-xs" :title="rule.condition_expression">
          {{ rule.condition_expression }}
        </span>
      </template>

      <template #cell-enabled="{ item: rule }">
        <span
          class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
          :class="
            rule.enabled
              ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
              : 'bg-slate-100 text-slate-600 dark:bg-slate-700 dark:text-slate-300'
          "
        >
          {{ rule.enabled ? 'Enabled' : 'Disabled' }}
        </span>
      </template>

      <template #row-actions="{ item: rule }">
        <button
          v-if="auth.can(PERMISSIONS.RULES_UPDATE)"
          type="button"
          title="Edit"
          aria-label="Edit rule"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="edit(rule)"
        >
          <IconEdit class="h-4 w-4" />
        </button>
        <button
          v-if="auth.can(PERMISSIONS.RULES_DELETE)"
          type="button"
          title="Delete"
          aria-label="Delete rule"
          class="rounded p-1.5 text-red-600 hover:bg-red-50 hover:text-red-800 dark:text-red-400 dark:hover:bg-red-900/30 dark:hover:text-red-300"
          @click="askDelete(rule)"
        >
          <IconDelete class="h-4 w-4" />
        </button>
      </template>
    </DataTable>

    <ConfirmDialog
      :open="!!pendingAction"
      :title="pendingAction?.type === 'bulk-delete' ? 'Delete rules' : 'Delete rule'"
      :message="
        pendingAction
          ? pendingAction.type === 'bulk-delete'
            ? `Delete ${pendingAction.ids.length} selected rules? This cannot be undone.`
            : `Delete rule '${pendingAction.rule.name}'?`
          : ''
      "
      confirm-label="Delete"
      @confirm="confirmPendingAction"
      @cancel="pendingAction = null"
    />
  </div>
</template>
