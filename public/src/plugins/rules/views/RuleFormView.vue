<script setup>
import { computed, onMounted, reactive, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useRulesStore } from "../../../stores/rules";
import { listRules } from "../../../services/api/rules";
import { HTTPError } from "../../../services/api/http";
import CodeEditor from "../../../components/common/CodeEditor.vue";

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useRulesStore();

const ruleId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!ruleId.value);

const EXAMPLE_SOURCE = `# name: a short identifier for this rule
# note: # only starts a comment at the beginning of a line - it is not
# supported after a value (e.g. "if: price<100 # comment" is NOT valid)
name:
# optional free-text description
description:
# boolean expression over: tags, source, item, item_id, price, discount,
# available, url, payload (case-insensitive on both sides)
# operators: = != > < >= <= has   |   combinators: AND OR NOT ( )   |   * matches anything
if: price < 300 AND available = true
# action: a free-form label, e.g. "notify-discord". Which notification
# channel(s) this maps to is decided elsewhere, not here
action: notify-discord
# optional: overrides the matched alert's severity (low/medium/high/critical),
# or defaulting to "low" when no rule sets it
severity:
# optional: comma-separated tags, replacing the alert's tags when this rule matches
tags:
# default true
enabled: true
`;

const form = reactive({
  source: isEdit.value ? "" : EXAMPLE_SOURCE,
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref("");

onMounted(async () => {
  if (!isEdit.value) return;

  const cached = store.findById(ruleId.value);
  if (cached) {
    form.source = cached.source;
    loading.value = false;
    return;
  }

  try {
    const { items } = await listRules({ id: ruleId.value });
    if (items && items[0]) {
      form.source = items[0].source;
    } else {
      error.value = "Rule not found.";
    }
  } catch (err) {
    error.value = "Failed to load rule.";
  } finally {
    loading.value = false;
  }
});

async function onSubmit() {
  error.value = "";
  // CodeEditor isn't a native form control, so the old textarea's `required`
  // attribute no longer blocks an empty submit - replicate that check here.
  if (!form.source.trim()) {
    error.value = "Rule source is required.";
    return;
  }
  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(ruleId.value, { source: form.source });
    } else {
      await store.create({ source: form.source });
    }
    router.push('/rules');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.error || body?.errors?.join(", ") || body?.message || "Save failed";
    } else {
      error.value = "Save failed";
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="max-w-2xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit rule #${ruleId}` : "New rule" }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div role="group" aria-labelledby="rule-source-label">
        <label id="rule-source-label" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Rule source</label>
        <CodeEditor v-model="form.source" language="yaml" />
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/rules"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? "Saving..." : "Save" }}
        </button>
      </div>
    </form>
  </div>
</template>
