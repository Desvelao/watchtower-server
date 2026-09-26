<script setup>
import { onMounted, reactive, ref } from 'vue';
import { testRule, testExpression } from '../../../services/api/rules';
import { HTTPError } from '../../../services/api/http';
import { useObservableTypesStore } from '../../../stores/observableTypes';

const observableTypesStore = useObservableTypesStore();

onMounted(() => {
  if (!observableTypesStore.items.length) observableTypesStore.fetchList();
});

const form = reactive({
  source: '',
  observable_id: '',
  worker: '',
  observable_type: '',
  payload: '',
  expression: '',
});

const testing = ref(false);
const error = ref('');
const matches = ref(null);
const expressionResult = ref(null);
const expressionError = ref('');

function toRequestBody() {
  const body = { source: form.source };

  if (form.observable_id !== '') body.observable_id = form.observable_id;
  if (form.worker !== '') body.worker = form.worker;
  if (form.observable_type !== '') body.observable_type = form.observable_type;
  if (form.payload.trim() !== '') body.payload = form.payload;

  return body;
}

async function onSubmit() {
  error.value = '';
  matches.value = null;
  expressionResult.value = null;
  expressionError.value = '';
  testing.value = true;
  try {
    const result = await testRule(toRequestBody());
    matches.value = result.matches || [];
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.errors?.join(', ') || body?.message || body?.error || 'Test failed';
    } else {
      error.value = 'Test failed';
    }
  }

  // Optional: also preview a draft `if:` expression against the same
  // sample observation, without it needing to be saved as a rule first.
  if (form.expression.trim()) {
    try {
      const result = await testExpression({ if: form.expression, ...toRequestBody() });
      expressionResult.value = result.matched;
    } catch (err) {
      if (err instanceof HTTPError) {
        const body = err.response.body;
        expressionError.value = body?.error || body?.message || 'Invalid expression';
      } else {
        expressionError.value = 'Invalid expression';
      }
    }
  }

  testing.value = false;
}
</script>

<template>
  <div class="max-w-xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">Test rules</h1>
    <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
      Enter a sample observation's properties to see which enabled
      <RouterLink to="/rules" class="underline">rules</RouterLink>
      would match and what alert(s) would be generated. Nothing here is saved - no observation or alert
      is created.
    </p>

    <form class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <fieldset class="space-y-4 rounded border border-slate-200 p-4 dark:border-slate-700">
        <legend class="px-1 text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Observation</legend>
        <div>
          <label for="test-source" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Source</label>
          <input id="test-source" v-model="form.source" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
        </div>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label for="test-observable-id" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Observable ID</label>
            <input id="test-observable-id" v-model="form.observable_id" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
          <div>
            <label for="test-worker" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Worker</label>
            <input id="test-worker" v-model="form.worker" type="text" placeholder="e.g. worker-lua" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
        </div>
        <div>
          <label for="test-observable-type" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Observable type</label>
          <select
            id="test-observable-type"
            v-model="form.observable_type"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          >
            <option value="">Any</option>
            <option v-for="type in observableTypesStore.items" :key="type.id" :value="type.name">
              {{ type.label || type.name }}
            </option>
          </select>
        </div>
        <div>
          <label for="test-payload" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Payload (JSON)</label>
          <textarea
            id="test-payload"
            v-model="form.payload"
            rows="3"
            placeholder='e.g. {"price": 250, "available": true}'
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
          <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            An observation's fields aren't individually testable here since they vary by observable type - enter the
            same JSON an observation's <code>properties</code> would have, and reference it in your expression as
            <code>payload.&lt;field&gt;</code>.
          </p>
        </div>
      </fieldset>

      <div>
        <label for="test-expression" class="block text-sm font-medium text-slate-700 dark:text-slate-300">
          Custom <code>if:</code> expression (optional)
        </label>
        <input
          id="test-expression"
          v-model="form.expression"
          type="text"
          placeholder='e.g. payload.price < 300 AND worker = "worker-lua"'
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Preview a draft condition against the sample observation above, without saving it as a rule.
        </p>
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end">
        <button
          type="submit"
          :disabled="testing"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ testing ? 'Testing...' : 'Test' }}
        </button>
      </div>
    </form>

    <div
      v-if="expressionResult !== null || expressionError"
      class="mt-6 rounded-lg border border-slate-200 bg-white p-4 text-sm dark:border-slate-700 dark:bg-slate-800"
    >
      <h2 class="text-sm font-medium text-slate-700 dark:text-slate-300">Custom expression result</h2>
      <p v-if="expressionError" class="mt-1 text-red-600 dark:text-red-400">{{ expressionError }}</p>
      <p v-else class="mt-1" :class="expressionResult ? 'text-green-700 dark:text-green-400' : 'text-slate-500 dark:text-slate-400'">
        {{ expressionResult ? 'Matches' : 'Does not match' }}
      </p>
    </div>

    <div v-if="matches" class="mt-6">
      <h2 class="text-sm font-medium text-slate-700 dark:text-slate-300">
        {{ matches.length === 0 ? 'No rule matched' : `${matches.length} rule${matches.length === 1 ? '' : 's'} matched` }}
      </h2>

      <ul v-if="matches.length" class="mt-2 space-y-2">
        <li
          v-for="(match, index) in matches"
          :key="match.id ?? index"
          class="rounded-lg border border-slate-200 bg-white p-4 text-sm dark:border-slate-700 dark:bg-slate-800"
        >
          <div class="flex items-center justify-between">
            <RouterLink
              v-if="match.id"
              :to="`/rules/${match.id}/edit`"
              class="font-medium text-slate-900 underline dark:text-slate-100"
            >
              Rule #{{ match.id }}
            </RouterLink>
          </div>
          <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-slate-500 dark:text-slate-400">
            <dt>Severity</dt>
            <dd class="text-slate-700 dark:text-slate-300">{{ match.severity || '-' }}</dd>
            <dt>Tags</dt>
            <dd class="text-slate-700 dark:text-slate-300">{{ (match.tags || []).join(', ') || '-' }}</dd>
          </dl>
        </li>
      </ul>
    </div>
  </div>
</template>
