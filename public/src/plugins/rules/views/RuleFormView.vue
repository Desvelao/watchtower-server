<script setup>
import { computed, onMounted, reactive, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useRulesStore } from "../../../stores/rules";
import { useObservableTypesStore } from "../../../stores/observableTypes";
import { listRules } from "../../../services/api/rules";
import { HTTPError } from "../../../services/api/http";
import CodeEditor from "../../../components/common/CodeEditor.vue";

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useRulesStore();
const observableTypesStore = useObservableTypesStore();

const ruleId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!ruleId.value);

const EXAMPLE_SOURCE = `# name: a short identifier for this rule
# note: # only starts a comment at the beginning of a line - it is not
# supported after a value (e.g. "if: payload.price<100 # comment" is NOT valid)
name:
# optional free-text description
description:
# boolean expression over: source, observable_id, worker, observable_type, payload,
# payload.<field> (case-insensitive on both sides) - see "Available fields"
# below for what payload.<field> is reachable per observable type
# operators: = != > < >= <= has in contains is_set changed changed_within
#            dropped_pct raised_pct older_than newer_than
#   |   combinators: AND OR NOT ( )   |   * matches anything
# payload.<field> changed: true if the value differs from
# the immediately preceding observation, if one exists.
# payload.<field> changed_within <duration>: same, but vs. the value <duration>
# ago. duration units: ms s m h d M (e.g. 30s, 1m, 2h, 3d) - or bare 0.
# no "unchanged" operator - use NOT (payload.price changed) instead.
# payload.<field> in ("a", "b"): shorthand for = "a" OR = "b" OR ...
# payload.<field> contains "x": case-insensitive plain substring match (not regex).
# payload.<field> is_set: true when present; use NOT (... is_set) for "absent".
# payload.<field> dropped_pct <percent> within <duration> / raised_pct: true when
# a numeric field fell/rose by at least <percent>% vs. its value <duration> ago.
# payload.<field> older_than <duration> / newer_than: for a date-typed field
# (ISO 8601 string), compares it against now - <duration>.
if: observable_type = "product" AND payload.price < 300
# optional: overrides the matched alert's severity (low/medium/high/critical),
# or defaulting to "low" when no rule sets it
severity:
# optional: comma-separated tags, replacing the alert's tags when this rule matches
tags:
# optional: suppresses re-alerting this rule for the same observable for this
# many seconds after it last fired (default: no cooldown)
cooldown_seconds:
# default true
enabled: true
`;

const form = reactive({
  source: isEdit.value ? "" : EXAMPLE_SOURCE,
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref("");

// Static, generic vocabulary - matches server/plugins/rules/allowed_fields.lua.
// No observable-type-specific field is ever listed directly; those are only
// reachable via payload.<field>, computed per observable type below.
const GENERIC_FIELDS = [
  { name: "source", ops: "= != in contains > < >= <=", meaning: "The observation's source (the observable's name)." },
  { name: "observable_id", ops: "= != in > < >= <=", meaning: "The id of the observable that was observed." },
  { name: "worker", ops: "= != in", meaning: "The id of the worker that produced the observation." },
  { name: "observable_type", ops: "= != in", meaning: "The name of the observable type the observed observable belongs to." },
  {
    name: "payload",
    ops: "= != in contains is_set > < >= <= changed changed_within",
    meaning:
      "The observation's properties, as a raw JSON string. changed/changed_within <duration> detect a change vs. the immediately preceding observation, or vs. one at least <duration> ago (units: ms s m h d M, e.g. 30s, 1m, 2h, 3d, or bare 0).",
  },
  {
    name: "payload.<field>",
    ops: "= != has in contains is_set > < >= <= changed changed_within dropped_pct raised_pct older_than newer_than",
    meaning:
      "One property from the observation's payload (see \"payload.* by observable type\" below for each type's field names). has: list membership. in (v1, v2, ...): shorthand for repeated =. contains: case-insensitive plain substring match. is_set: present (use NOT (... is_set) for absent). dropped_pct/raised_pct <percent> within <duration>: numeric percent change vs. a baseline. older_than/newer_than <duration>: for a date-typed field, vs. now.",
  },
];

onMounted(async () => {
  if (!observableTypesStore.items.length) await observableTypesStore.fetchList();

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
  <div class="max-w-5xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit rule #${ruleId}` : "New rule" }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <div v-else class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-3">
      <form class="space-y-4 rounded-lg border border-slate-200 bg-white p-5 lg:col-span-2 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
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

      <div class="space-y-4 rounded-lg border border-slate-200 bg-white p-5 text-sm dark:border-slate-700 dark:bg-slate-800">
        <div>
          <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Available fields</h2>
          <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            Fields an <code>if:</code> expression can reference. Observable-type-specific observation fields are
            only reachable via <code>payload.&lt;field&gt;</code> - see below for each type's fields.
          </p>
        </div>

        <dl class="space-y-2">
          <div v-for="field in GENERIC_FIELDS" :key="field.name" class="border-b border-slate-100 pb-2 last:border-0 last:pb-0 dark:border-slate-700">
            <dt class="font-mono text-xs font-medium text-slate-900 dark:text-slate-100">
              {{ field.name }}
              <span class="ml-1 font-sans font-normal text-slate-400 dark:text-slate-500">{{ field.ops }}</span>
            </dt>
            <dd class="text-xs text-slate-600 dark:text-slate-400">{{ field.meaning }}</dd>
          </div>
        </dl>

        <div v-if="observableTypesStore.items.length">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
            payload.* by observable type
          </h3>
          <div v-for="observableType in observableTypesStore.items" :key="observableType.id" class="mt-2">
            <p class="text-xs font-medium text-slate-700 dark:text-slate-300">
              {{ observableType.label || observableType.name }}
              <span class="ml-1 font-mono font-normal text-slate-400 dark:text-slate-500">
                observable_type = "{{ observableType.name }}"
              </span>
            </p>
            <ul v-if="observableType.observation_schema?.length" class="mt-1 space-y-1">
              <li v-for="prop in observableType.observation_schema" :key="prop.name" class="font-mono text-xs text-slate-600 dark:text-slate-400">
                payload.{{ prop.name }}
                <span class="font-sans text-slate-400 dark:text-slate-500">
                  &mdash; {{ prop.type }}{{ prop.required ? ', required' : '' }}
                </span>
              </li>
            </ul>
            <p v-else class="mt-1 text-xs text-slate-400 dark:text-slate-500">No observation fields defined.</p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
