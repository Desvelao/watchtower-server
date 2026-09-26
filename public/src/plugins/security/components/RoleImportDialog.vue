<script setup>
import { computed, ref, watch } from 'vue';
import { preflightRolesImport, commitRolesImport } from '../../../services/api/roles';
import { HTTPError } from '../../../services/api/http';

const props = defineProps({
  open: { type: Boolean, default: false },
});

const emit = defineEmits(['close', 'imported']);

// One entry per preflight candidate, in the same order the server
// returned them. `action` is what will actually be sent on commit:
// - error rows: always null (excluded, unresolvable)
// - no-conflict rows: 'create' by default, toggled by a checkbox
// - conflict rows: 'skip' by default (safer than silently overwriting an
//   existing role), or 'update'/'create' via a select
const candidates = ref([]);
const actions = ref([]); // parallel array: 'create' | 'update' | 'skip' | null
const stage = ref('pick'); // 'pick' | 'preflighting' | 'review' | 'committing' | 'results'
const error = ref('');
const results = ref(null); // parallel array to the *sent* candidates, after commit
const sentCandidates = ref([]);
const fileInput = ref(null);

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) reset();
  },
);

function reset() {
  candidates.value = [];
  actions.value = [];
  stage.value = 'pick';
  error.value = '';
  results.value = null;
  sentCandidates.value = [];
  if (fileInput.value) fileInput.value.value = '';
}

async function onFileChange(event) {
  const file = event.target.files[0];
  if (!file) return;

  error.value = '';
  stage.value = 'preflighting';
  try {
    const { items } = await preflightRolesImport(file);
    candidates.value = items || [];
    actions.value = candidates.value.map((c) => {
      if (c.error) return null;
      return c.conflict ? 'skip' : 'create';
    });
    stage.value = 'review';
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || 'Failed to read file.' : 'Failed to read file.';
    stage.value = 'pick';
  }
}

const includedCount = computed(() => actions.value.filter((a) => a === 'create' || a === 'update').length);

function toggleInclude(index, included) {
  actions.value[index] = included ? 'create' : 'skip';
}

function setConflictAction(index, action) {
  actions.value[index] = action;
}

async function onCommit() {
  const payload = [];
  const sent = [];
  candidates.value.forEach((c, i) => {
    const action = actions.value[i];
    if (action === 'create' || action === 'update') {
      payload.push({
        name: c.name,
        permissions: c.permissions,
        action,
        existing_id: c.conflict ? c.conflict.id : undefined,
      });
      sent.push(c);
    }
  });

  error.value = '';
  stage.value = 'committing';
  try {
    const { results: res } = await commitRolesImport(payload);
    results.value = res || [];
    sentCandidates.value = sent;
    stage.value = 'results';
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || 'Import failed.' : 'Import failed.';
    stage.value = 'review';
  }
}

const successCount = computed(() => (results.value || []).filter((r) => r.ok).length);

function onDone() {
  emit('imported');
  emit('close');
}

function onCancel() {
  emit('close');
}
</script>

<template>
  <div
    v-if="open"
    role="dialog"
    aria-modal="true"
    aria-label="Import roles"
    class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4"
    @click.self="onCancel"
  >
    <div class="w-full max-w-2xl rounded-lg bg-white p-5 shadow-xl dark:bg-slate-800">
      <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">Import roles</h2>

      <div v-if="stage === 'pick' || stage === 'preflighting'" class="mt-4">
        <p class="text-sm text-slate-600 dark:text-slate-400">
          Choose a previously-exported <code>.json</code> file, or a <code>.zip</code> of several.
        </p>
        <input
          ref="fileInput"
          type="file"
          accept=".json,.zip"
          :disabled="stage === 'preflighting'"
          class="mt-3 block w-full text-sm text-slate-600 file:mr-3 file:rounded file:border-0 file:bg-slate-100 file:px-3 file:py-1.5 file:text-sm file:font-medium file:text-slate-700 hover:file:bg-slate-200 dark:text-slate-400 dark:file:bg-slate-700 dark:file:text-slate-200"
          @change="onFileChange"
        />
        <p v-if="stage === 'preflighting'" class="mt-2 text-sm text-slate-500 dark:text-slate-400">Reading file...</p>
        <p v-if="error" class="mt-2 text-sm text-red-600 dark:text-red-400">{{ error }}</p>
      </div>

      <div v-else-if="stage === 'review' || stage === 'committing'" class="mt-4">
        <p v-if="error" class="mb-2 text-sm text-red-600 dark:text-red-400">{{ error }}</p>
        <div class="max-h-96 space-y-2 overflow-y-auto">
          <div
            v-for="(candidate, i) in candidates"
            :key="candidate.file + i"
            class="flex items-center justify-between gap-3 rounded border border-slate-200 px-3 py-2 text-sm dark:border-slate-700"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate font-mono text-xs text-slate-500 dark:text-slate-400">{{ candidate.file }}</p>
              <p v-if="candidate.error" class="text-red-600 dark:text-red-400">{{ candidate.error }}</p>
              <p v-else class="font-medium text-slate-900 dark:text-slate-100">
                {{ candidate.name }}
                <span v-if="candidate.conflict" class="ml-1 font-normal text-amber-700 dark:text-amber-400">
                  conflicts with existing role #{{ candidate.conflict.id }}
                </span>
              </p>
            </div>

            <label v-if="!candidate.error && !candidate.conflict" class="flex shrink-0 items-center gap-1.5 text-slate-600 dark:text-slate-300">
              <input
                type="checkbox"
                :checked="actions[i] === 'create'"
                :disabled="stage === 'committing'"
                @change="toggleInclude(i, $event.target.checked)"
              />
              Import
            </label>

            <select
              v-else-if="!candidate.error && candidate.conflict"
              :value="actions[i]"
              :disabled="stage === 'committing'"
              class="shrink-0 rounded border border-slate-300 px-2 py-1 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
              @change="setConflictAction(i, $event.target.value)"
            >
              <option value="skip">Skip</option>
              <option value="update">Update existing</option>
              <option value="create">Import as new</option>
            </select>
          </div>
        </div>
      </div>

      <div v-else-if="stage === 'results'" class="mt-4">
        <p class="text-sm text-slate-700 dark:text-slate-300">
          {{ successCount }} of {{ results.length }} imported.
        </p>
        <ul v-if="successCount < results.length" class="mt-2 space-y-1 text-sm">
          <li v-for="(r, i) in results" :key="i">
            <span v-if="!r.ok" class="text-red-600 dark:text-red-400">
              {{ sentCandidates[i].name || sentCandidates[i].file }}: {{ r.error }}
            </span>
          </li>
        </ul>
      </div>

      <div class="mt-5 flex justify-end gap-2">
        <button
          v-if="stage !== 'results'"
          type="button"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="onCancel"
        >
          Cancel
        </button>
        <button
          v-if="stage === 'review' || stage === 'committing'"
          type="button"
          :disabled="includedCount === 0 || stage === 'committing'"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
          @click="onCommit"
        >
          {{ stage === 'committing' ? 'Importing...' : `Import ${includedCount} role${includedCount === 1 ? '' : 's'}` }}
        </button>
        <button
          v-if="stage === 'results'"
          type="button"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 dark:bg-slate-700 dark:hover:bg-slate-600"
          @click="onDone"
        >
          Done
        </button>
      </div>
    </div>
  </div>
</template>
