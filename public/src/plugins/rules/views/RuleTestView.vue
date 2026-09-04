<script setup>
import { reactive, ref } from 'vue';
import { testRule, testExpression } from '../../../services/api/rules';
import { HTTPError } from '../../../services/api/http';

const form = reactive({
  source: '',
  tags: '',
  item_id: '',
  price: '',
  discount: '',
  available: '',
  url: '',
  expression: '',
});

const testing = ref(false);
const error = ref('');
const matches = ref(null);
const expressionResult = ref(null);
const expressionError = ref('');

function toRequestBody() {
  const tags = form.tags
    .split(',')
    .map((t) => t.trim())
    .filter(Boolean);

  const body = { source: form.source };

  if (tags.length > 0) body.tags = tags;
  if (form.item_id !== '') body.item_id = form.item_id;
  if (form.price !== '') body.price = Number(form.price);
  if (form.discount !== '') body.discount = form.discount;
  if (form.available !== '') body.available = form.available === 'true';
  if (form.url !== '') body.url = form.url;

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
  // sample event, without it needing to be saved as a rule first.
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
      Enter a sample event's properties to see which enabled
      <RouterLink to="/rules" class="underline">rules</RouterLink>
      would match and what alert(s) would be generated. Nothing here is saved - no event or alert is
      created.
    </p>

    <form class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <fieldset class="space-y-4 rounded border border-slate-200 p-4 dark:border-slate-700">
        <legend class="px-1 text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Event</legend>
        <div>
          <label for="test-source" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Source</label>
          <input id="test-source" v-model="form.source" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
        </div>
        <div>
          <label for="test-tags" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Tags</label>
          <input
            id="test-tags"
            v-model="form.tags"
            type="text"
            placeholder="comma, separated, tags"
            class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label for="test-item-id" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Item ID</label>
            <input id="test-item-id" v-model="form.item_id" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
          <div>
            <label for="test-price" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Price</label>
            <input id="test-price" v-model="form.price" type="number" step="0.01" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
          <div>
            <label for="test-discount" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Discount</label>
            <input id="test-discount" v-model="form.discount" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
          <div>
            <label for="test-available" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Available</label>
            <select id="test-available" v-model="form.available" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100">
              <option value="">-</option>
              <option value="true">true</option>
              <option value="false">false</option>
            </select>
          </div>
        </div>
        <div>
          <label for="test-url" class="block text-sm font-medium text-slate-700 dark:text-slate-300">URL</label>
          <input id="test-url" v-model="form.url" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
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
          placeholder='e.g. price < 300 AND available = true'
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 font-mono text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Preview a draft condition against the sample event above, without saving it as a rule.
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
            <span class="font-mono text-xs text-slate-500 dark:text-slate-400">{{ match.action }}</span>
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
