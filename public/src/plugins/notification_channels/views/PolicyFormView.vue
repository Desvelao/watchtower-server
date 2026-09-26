<script setup>
import { computed, onMounted, reactive, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useNotificationPoliciesStore } from "../../../stores/notificationPolicies";
import { useNotificationChannelsStore } from "../../../stores/notificationChannels";
import { listPolicies, testPolicyExpression } from "../../../services/api/notification_policies";
import { HTTPError } from "../../../services/api/http";
import CodeEditor from "../../../components/common/CodeEditor.vue";

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useNotificationPoliciesStore();
const channelsStore = useNotificationChannelsStore();

const policyId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!policyId.value);

const EXAMPLE_SOURCE = `# name: a short identifier for this policy
# note: # only starts a comment at the beginning of a line - it is not
# supported after a value
name:
# optional free-text description
description:
# boolean expression over an ALERT's own fields: severity, tags, rule_id,
# observable_id (case-insensitive on both sides) - see "Available
# fields" below. This is different from a Rule's "if" (which matches an
# observation's payload) - a policy matches the alert a rule already fired.
# operators: = != in > < >= <= has   |   combinators: AND OR NOT ( )   |   * matches anything
# severity's >/</>=/<= rank semantically: low < medium < high < critical.
if: severity = "high" OR severity = "critical"
# required: comma-separated notification_channels ids to notify when this
# policy matches - see the ids in the Notification Channels list.
channels:
# optional: comma-separated tags
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

// Matches server/plugins/notification_channels/allowed_fields.lua.
const ALERT_FIELDS = [
  {
    name: "severity",
    ops: "= != in > < >= <=",
    meaning: "The alert's severity (low/medium/high/critical). >/</>=/<= rank semantically (low < medium < high < critical), not alphabetically.",
  },
  { name: "tags", ops: "has", meaning: "The alert's tags, inherited from the matching rule." },
  { name: "rule_id", ops: "= != in", meaning: "The id of the rule that fired this alert." },
  { name: "observable_id", ops: "= != in > < >= <=", meaning: "The id of the observable the underlying observation belongs to." },
];

const testForm = reactive({ expression: "", severity: "", tags: "", rule_id: "", observable_id: "" });
const testing = ref(false);
const testResult = ref(null);
const testError = ref("");

async function onTest() {
  testError.value = "";
  testResult.value = null;
  if (!testForm.expression.trim()) {
    testError.value = "Enter an expression to test.";
    return;
  }
  testing.value = true;
  try {
    const result = await testPolicyExpression({
      if: testForm.expression,
      severity: testForm.severity || undefined,
      tags: testForm.tags
        ? testForm.tags.split(",").map((t) => t.trim()).filter(Boolean)
        : undefined,
      rule_id: testForm.rule_id || undefined,
      observable_id: testForm.observable_id || undefined,
    });
    testResult.value = result.matched;
  } catch (err) {
    testError.value = err instanceof HTTPError ? err.response.body?.error || err.response.body?.message || "Invalid expression" : "Test failed";
  } finally {
    testing.value = false;
  }
}

onMounted(async () => {
  if (!channelsStore.items.length) await channelsStore.fetchList();

  if (!isEdit.value) return;

  const cached = store.findById(policyId.value);
  if (cached) {
    form.source = cached.source;
    loading.value = false;
    return;
  }

  try {
    const { items } = await listPolicies({ id: policyId.value });
    if (items && items[0]) {
      form.source = items[0].source;
    } else {
      error.value = "Notification policy not found.";
    }
  } catch (err) {
    error.value = "Failed to load notification policy.";
  } finally {
    loading.value = false;
  }
});

async function onSubmit() {
  error.value = "";
  if (!form.source.trim()) {
    error.value = "Policy source is required.";
    return;
  }
  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(policyId.value, { source: form.source });
    } else {
      await store.create({ source: form.source });
    }
    router.push('/notification_policies');
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
      {{ isEdit ? `Edit notification policy #${policyId}` : "New notification policy" }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <div v-else class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-3">
      <form class="space-y-4 rounded-lg border border-slate-200 bg-white p-5 lg:col-span-2 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
        <div role="group" aria-labelledby="policy-source-label">
          <label id="policy-source-label" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Policy source</label>
          <CodeEditor v-model="form.source" language="yaml" />
        </div>

        <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

        <div class="flex justify-end gap-2">
          <RouterLink
            to="/notification_policies"
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

      <div class="space-y-6">
        <div class="space-y-4 rounded-lg border border-slate-200 bg-white p-5 text-sm dark:border-slate-700 dark:bg-slate-800">
          <div>
            <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Available fields</h2>
            <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
              Fields an <code>if:</code> expression can reference - these are the fired ALERT's own fields, not
              the underlying observation's payload (contrast a Rule's <code>if:</code>).
            </p>
          </div>

          <dl class="space-y-2">
            <div v-for="field in ALERT_FIELDS" :key="field.name" class="border-b border-slate-100 pb-2 last:border-0 last:pb-0 dark:border-slate-700">
              <dt class="font-mono text-xs font-medium text-slate-900 dark:text-slate-100">
                {{ field.name }}
                <span class="ml-1 font-sans font-normal text-slate-400 dark:text-slate-500">{{ field.ops }}</span>
              </dt>
              <dd class="text-xs text-slate-600 dark:text-slate-400">{{ field.meaning }}</dd>
            </div>
          </dl>

          <div v-if="channelsStore.items.length">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">Channel ids</h3>
            <ul class="mt-1 space-y-1">
              <li v-for="channel in channelsStore.items" :key="channel.id" class="font-mono text-xs text-slate-600 dark:text-slate-400">
                {{ channel.id }} <span class="font-sans text-slate-400 dark:text-slate-500">&mdash; {{ channel.name }} ({{ channel.type }})</span>
              </li>
            </ul>
          </div>
        </div>

        <div class="space-y-3 rounded-lg border border-slate-200 bg-white p-5 text-sm dark:border-slate-700 dark:bg-slate-800">
          <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Test an expression</h2>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            Preview a draft <code>if:</code> expression against a sample alert, without saving anything.
          </p>
          <input
            v-model="testForm.expression"
            type="text"
            placeholder='e.g. severity = "high"'
            class="w-full rounded border border-slate-300 px-2 py-1.5 font-mono text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
          <div class="grid grid-cols-2 gap-2">
            <input v-model="testForm.severity" type="text" placeholder="severity" class="rounded border border-slate-300 px-2 py-1.5 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
            <input v-model="testForm.tags" type="text" placeholder="tags (comma separated)" class="rounded border border-slate-300 px-2 py-1.5 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
            <input v-model="testForm.rule_id" type="text" placeholder="rule_id" class="rounded border border-slate-300 px-2 py-1.5 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
            <input v-model="testForm.observable_id" type="text" placeholder="observable_id" class="rounded border border-slate-300 px-2 py-1.5 text-xs dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
          </div>
          <button
            type="button"
            :disabled="testing"
            class="rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
            @click="onTest"
          >
            {{ testing ? "Testing..." : "Test" }}
          </button>
          <p v-if="testError" class="text-xs text-red-600 dark:text-red-400">{{ testError }}</p>
          <p v-else-if="testResult !== null" class="text-xs" :class="testResult ? 'text-green-700 dark:text-green-400' : 'text-slate-500 dark:text-slate-400'">
            {{ testResult ? "Matches" : "Does not match" }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
