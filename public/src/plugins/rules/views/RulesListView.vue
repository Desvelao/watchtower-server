<script setup>
import { computed, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useRulesStore } from '../../../stores/rules';
import { useAuthStore } from '../../../stores/auth';
import { exportRules } from '../../../services/api/rules';
import { HTTPError } from '../../../services/api/http';
import { downloadBlob } from '../../../utils/download';
import DataTable from '../../../components/common/DataTable.vue';
import ConfirmDialog from '../../../components/common/ConfirmDialog.vue';
import EnabledBadge from '../../../components/common/EnabledBadge.vue';
import RuleImportDialog from '../components/RuleImportDialog.vue';
import RuleDetailsFlyout from '../components/RuleDetailsFlyout.vue';
import IconEye from '../../../components/common/icons/IconEye.vue';
import IconEdit from '../../../components/common/icons/IconEdit.vue';
import IconCopy from '../../../components/common/icons/IconCopy.vue';
import IconDelete from '../../../components/common/icons/IconDelete.vue';
import IconFlask from '../../../components/common/icons/IconFlask.vue';
import IconDownload from '../../../components/common/icons/IconDownload.vue';
import IconUpload from '../../../components/common/icons/IconUpload.vue';
import { formatDate } from '../../../utils/date';
import { useFilterRouteSync } from '../../../composables/useFilterRouteSync';
import { PERMISSIONS } from '../../../constants/permissions';

const store = useRulesStore();
const auth = useAuthStore();
const route = useRoute();
const router = useRouter();

const pendingAction = ref(null); // { type: 'delete', rule } | { type: 'bulk-delete', ids }
const bulkError = ref('');
const importOpen = ref(false);
const duplicatingId = ref(null);

const columns = [
  { key: 'name', label: 'Name', sortable: true, class: 'font-medium' },
  { key: 'condition_expression', label: 'Condition' },
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

const detailsRuleId = computed(() => route.query.details || null);

function viewDetails(rule) {
  router.push({ query: { ...route.query, details: rule.id } });
}

function closeDetails() {
  const query = { ...route.query };
  delete query.details;
  router.push({ query });
}

function edit(rule) {
  router.push(`/rules/${rule.id}/edit`);
}

// Quotes a value for the flat rule-source format (rule_source.lua's
// coerce_value): wraps it in double quotes and escapes backslashes/quotes
// so it round-trips through the parser unchanged.
function quoteSourceValue(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

// Builds a duplicate's rule "source" document from an existing rule's own
// source text - same if/description/severity/tags/cooldown_seconds (and
// any comments) line-for-line, but with '(copy)' appended to the name and
// forced disabled. Editing the raw source directly (rather than
// re-deriving it from the row's parsed fields) preserves everything about
// how the rule was originally authored; see
// server/shared/rule_engine/source.lua for the flat "key: value"
// format this relies on (one key per non-comment line, first match wins).
function buildDuplicateSource(rule) {
  const newName = `${rule.name} (copy)`;
  const lines = rule.source.split('\n');
  let nameHandled = false;
  let enabledHandled = false;

  const outLines = lines.map((line) => {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) return line;
    const colonIdx = trimmed.indexOf(':');
    if (colonIdx === -1) return line;
    const key = trimmed.slice(0, colonIdx).trim();
    if (key === 'name' && !nameHandled) {
      nameHandled = true;
      return `name: ${quoteSourceValue(newName)}`;
    }
    if (key === 'enabled' && !enabledHandled) {
      enabledHandled = true;
      return 'enabled: false';
    }
    return line;
  });

  if (!nameHandled) outLines.push(`name: ${quoteSourceValue(newName)}`);
  if (!enabledHandled) outLines.push('enabled: false');

  return outLines.join('\n');
}

async function duplicate(rule) {
  bulkError.value = '';
  duplicatingId.value = rule.id;
  try {
    const created = await store.create({ source: buildDuplicateSource(rule) });
    router.push(`/rules/${created.id}/edit`);
  } catch (err) {
    bulkError.value =
      err instanceof HTTPError ? err.response.body?.message || err.response.body?.error || 'Failed to duplicate rule.' : 'Failed to duplicate rule.';
  } finally {
    duplicatingId.value = null;
  }
}

function askDelete(rule) {
  pendingAction.value = { type: 'delete', rule };
}

function askBulkDelete(ids) {
  pendingAction.value = { type: 'bulk-delete', ids: [...ids] };
}

async function exportAndDownload(ids) {
  bulkError.value = '';
  try {
    const { content, contentType } = await exportRules(ids);
    const isZip = contentType.includes('zip');
    downloadBlob(content, isZip ? 'rules-export.zip' : 'rules-export.yaml', isZip ? 'application/zip' : 'text/yaml');
  } catch (err) {
    bulkError.value = err instanceof HTTPError ? err.response.body?.message || 'Failed to export rules.' : 'Failed to export rules.';
  }
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
      :date-range="dateRangeField"
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
        <button
          v-if="auth.can(PERMISSIONS.RULES_CREATE)"
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
          Boolean-expression rules evaluated against each incoming observation to resolve its dispatch
          action, and optionally override severity or tags.
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

      <template #cell-condition_expression="{ item: rule }">
        <span class="block max-w-[280px] truncate font-mono text-xs" :title="rule.condition_expression">
          {{ rule.condition_expression }}
        </span>
      </template>

      <template #cell-enabled="{ item: rule }">
        <EnabledBadge :enabled="rule.enabled" />
      </template>

      <template #cell-created_at="{ item: rule }">{{ formatDate(rule.created_at) }}</template>

      <template #row-actions="{ item: rule }">
        <button
          type="button"
          title="View details"
          aria-label="View rule details"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="viewDetails(rule)"
        >
          <IconEye class="h-4 w-4" />
        </button>
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
          v-if="auth.can(PERMISSIONS.RULES_CREATE)"
          type="button"
          title="Duplicate"
          aria-label="Duplicate rule"
          :disabled="duplicatingId === rule.id"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 disabled:opacity-50 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="duplicate(rule)"
        >
          <IconCopy class="h-4 w-4" />
        </button>
        <button
          type="button"
          title="Export"
          aria-label="Export rule"
          class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="exportAndDownload([rule.id])"
        >
          <IconDownload class="h-4 w-4" />
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

    <RuleImportDialog
      :open="importOpen"
      @close="importOpen = false"
      @imported="store.fetchList()"
    />

    <RuleDetailsFlyout :rule-id="detailsRuleId" @close="closeDetails" />
  </div>
</template>
