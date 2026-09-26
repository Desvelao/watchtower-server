<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useSchedulerStore } from '../../../stores/scheduler';
import { useObservableTypesStore } from '../../../stores/observableTypes';
import { useNotificationPoliciesStore } from '../../../stores/notificationPolicies';
import { listTasks, previewCron } from '../../../services/api/scheduler';
import { listObservables } from '../../../services/api/observables';
import { HTTPError } from '../../../services/api/http';
import { formatDate, localDateTimeToServerParam, serverDateToLocalDateTimeValue } from '../../../utils/date';

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useSchedulerStore();
const observableTypesStore = useObservableTypesStore();
const policiesStore = useNotificationPoliciesStore();

const jobId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!jobId.value);

const form = reactive({
  type: 'observe', // 'observe' | 'analyze' | 'notify' | 'deliver'
  name: '',
  observable_type_id: '',
  targetMode: 'all', // 'all' | 'specific'
  observable_ids: [],
  notify_policy_ids: [],
  schedule_type: 'cron',
  cron_expression: '0 * * * *',
  run_at: '',
  runNow: true,
  runNowCron: false,
  enabled: true,
});

// 'deliver' has no target of its own at all (no observable scope, no
// notify_policy_ids) - it just means "drain the pending alert_deliveries
// queue on this schedule", an alternative to a "deliver"-role worker's own
// independent alert_deliveries polling (see that worker's deliver.source
// config) - so it renders neither the observable-scoped block nor the
// notify_policy_ids block below.
const isObservableScoped = computed(() => form.type === 'observe' || form.type === 'analyze');
const isNotify = computed(() => form.type === 'notify');
const isDeliver = computed(() => form.type === 'deliver');

const loading = ref(true);
const saving = ref(false);
const error = ref('');
const observables = ref([]);
const observablesLoading = ref(false);

const previewRuns = ref([]);
const previewError = ref('');
const previewing = ref(false);

async function loadObservablesForObservableType() {
  if (!form.observable_type_id) {
    observables.value = [];
    return;
  }
  observablesLoading.value = true;
  try {
    const { items: fetched } = await listObservables({ observable_type_id: form.observable_type_id, size: 500 });
    observables.value = fetched || [];
  } catch (err) {
    observables.value = [];
  } finally {
    observablesLoading.value = false;
  }
}

watch(() => form.observable_type_id, loadObservablesForObservableType);

onMounted(async () => {
  if (!observableTypesStore.items.length) await observableTypesStore.fetchList();
  if (!policiesStore.items.length) await policiesStore.fetchList();

  if (!isEdit.value) {
    loading.value = false;
    return;
  }

  const cached = store.findById(jobId.value);
  const existing =
    cached ||
    (await listTasks({ id: jobId.value }).then((res) => res.items?.[0]).catch(() => null));

  if (existing) {
    form.type = existing.type || 'observe';
    form.name = existing.name;
    form.observable_type_id = existing.observable_type_id;
    form.targetMode = existing.observable_ids && existing.observable_ids.length ? 'specific' : 'all';
    form.observable_ids = existing.observable_ids ? [...existing.observable_ids] : [];
    form.notify_policy_ids = existing.notify_policy_ids ? [...existing.notify_policy_ids] : [];
    form.schedule_type = existing.schedule_type;
    form.cron_expression = existing.cron_expression || '0 * * * *';
    form.run_at = serverDateToLocalDateTimeValue(existing.run_at);
    form.runNow = false;
    form.runNowCron = false;
    form.enabled = existing.enabled;
    if (isObservableScoped.value) await loadObservablesForObservableType();
  } else {
    error.value = 'Scheduler task not found.';
  }
  loading.value = false;
});

async function onPreviewCron() {
  previewError.value = '';
  previewRuns.value = [];
  previewing.value = true;
  try {
    const { next_runs } = await previewCron({ cron_expression: form.cron_expression, count: 5 });
    previewRuns.value = next_runs || [];
  } catch (err) {
    previewError.value =
      err instanceof HTTPError ? err.response.body?.message || 'Invalid expression' : 'Invalid expression';
  } finally {
    previewing.value = false;
  }
}

async function onSubmit() {
  error.value = '';

  if (isObservableScoped.value && !form.observable_type_id) {
    error.value = 'Observable type is required.';
    return;
  }
  if (isObservableScoped.value && form.targetMode === 'specific' && form.observable_ids.length === 0) {
    error.value = 'Select at least one observable, or choose "All observables".';
    return;
  }

  const payload = {
    name: form.name,
    schedule_type: form.schedule_type,
    enabled: form.enabled,
  };
  if (!isEdit.value) {
    payload.type = form.type;
  }
  // Omit observable_ids/notify_policy_ids entirely for the wildcard case - the
  // server validation (types.empty + types.array_of(types.number)) rejects
  // a JSON `null`, it only accepts an empty/missing value or a real array.
  // 'deliver' needs neither - it has no target of its own at all.
  if (isNotify.value) {
    if (form.notify_policy_ids.length) {
      payload.notify_policy_ids = form.notify_policy_ids.map(Number);
    }
  } else if (isObservableScoped.value) {
    if (!isEdit.value) {
      payload.observable_type_id = form.observable_type_id;
    }
    if (form.targetMode === 'specific') {
      payload.observable_ids = form.observable_ids.map(Number);
    }
  }
  if (form.schedule_type === 'cron') {
    payload.cron_expression = form.cron_expression;
    if (form.runNowCron) {
      payload.run_now = true;
    }
  } else if (!form.runNow) {
    payload.run_at = localDateTimeToServerParam(form.run_at);
  }

  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(jobId.value, payload);
    } else {
      await store.create(payload);
    }
    router.push('/scheduler');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.message || body?.error || 'Save failed';
    } else {
      error.value = 'Save failed';
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="max-w-2xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit scheduler task #${jobId}` : 'New scheduler task' }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form
      v-else
      class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800"
      @submit.prevent="onSubmit"
    >
      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="job-name">Name</label>
        <input
          id="job-name"
          v-model="form.name"
          type="text"
          required
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">Task type</label>
        <div class="mt-1 flex flex-wrap items-center gap-4">
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.type" type="radio" value="observe" :disabled="isEdit" />
            Observe observables
          </label>
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.type" type="radio" value="analyze" :disabled="isEdit" />
            Analyze observables
          </label>
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.type" type="radio" value="notify" :disabled="isEdit" />
            Notify
          </label>
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.type" type="radio" value="deliver" :disabled="isEdit" />
            Deliver
          </label>
        </div>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">Immutable after creation.</p>
      </div>

      <template v-if="isObservableScoped">
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="job-observable-type">Observable type</label>
          <select
            id="job-observable-type"
            v-model="form.observable_type_id"
            required
            :disabled="isEdit"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm disabled:opacity-50 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          >
            <option value="" disabled>Select an observable type…</option>
            <option v-for="t in observableTypesStore.items" :key="t.id" :value="t.id">{{ t.label || t.name }}</option>
          </select>
        </div>

        <div v-if="form.observable_type_id">
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">Target</label>
          <div class="mt-1 flex items-center gap-4">
            <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
              <input v-model="form.targetMode" type="radio" value="all" />
              All observables of this observable type
            </label>
            <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
              <input v-model="form.targetMode" type="radio" value="specific" />
              Specific observables
            </label>
          </div>

          <select
            v-if="form.targetMode === 'specific'"
            v-model="form.observable_ids"
            multiple
            size="6"
            class="mt-2 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          >
            <option v-for="observable in observables" :key="observable.id" :value="String(observable.id)">{{ observable.name }}</option>
          </select>
          <p v-if="form.targetMode === 'specific' && observablesLoading" class="mt-1 text-xs text-slate-400">Loading observables…</p>
        </div>
      </template>

      <div v-else-if="isNotify">
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="job-notify-policies">
          Notification policies
        </label>
        <select
          id="job-notify-policies"
          v-model="form.notify_policy_ids"
          multiple
          size="6"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option v-for="policy in policiesStore.items" :key="policy.id" :value="String(policy.id)">{{ policy.name }}</option>
        </select>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Leave empty to evaluate every enabled
          <RouterLink to="/notification_policies" class="underline">notification policy</RouterLink>.
        </p>
      </div>

      <p v-else-if="isDeliver" class="text-sm text-slate-500 dark:text-slate-400">
        Drains whatever's currently pending on the alert_deliveries queue and sends it - no target to configure.
        Only used by a "deliver" worker whose <code>deliver.source</code> config is set to <code>"queue"</code>;
        a worker left on the default <code>"deliveries"</code> source ignores this task type entirely.
      </p>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">Schedule</label>
        <div class="mt-1 flex items-center gap-4">
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.schedule_type" type="radio" value="cron" />
            Recurring (cron)
          </label>
          <label class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300">
            <input v-model="form.schedule_type" type="radio" value="one_shot" />
            One-shot
          </label>
        </div>
      </div>

      <div v-if="form.schedule_type === 'cron'">
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="job-cron">
          Cron expression
        </label>
        <div class="mt-1 flex gap-2">
          <input
            id="job-cron"
            v-model="form.cron_expression"
            type="text"
            placeholder="e.g. */15 * * * *"
            class="w-full rounded border border-slate-300 px-2 py-1.5 text-sm font-mono dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
          <button
            type="button"
            :disabled="previewing"
            class="shrink-0 rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
            @click="onPreviewCron"
          >
            Preview
          </button>
        </div>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          minute hour day-of-month month day-of-week (e.g. <code>*/15 * * * *</code>, <code>0 9 * * 1-5</code>)
        </p>
        <p v-if="previewError" class="mt-1 text-xs text-red-600 dark:text-red-400">{{ previewError }}</p>
        <ul v-if="previewRuns.length" class="mt-1 space-y-0.5 text-xs text-slate-600 dark:text-slate-400">
          <li v-for="run in previewRuns" :key="run">{{ formatDate(run) }}</li>
        </ul>

        <label class="mt-2 flex items-center gap-2 text-sm text-slate-700 dark:text-slate-300">
          <input v-model="form.runNowCron" type="checkbox" />
          Run now (in addition to the schedule above)
        </label>
      </div>

      <div v-else class="space-y-2">
        <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-300">
          <input v-model="form.runNow" type="checkbox" />
          Run now
        </label>
        <div v-if="!form.runNow">
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="job-run-at">Run at</label>
          <input
            id="job-run-at"
            v-model="form.run_at"
            type="datetime-local"
            :required="!form.runNow"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
      </div>

      <div class="flex items-center gap-2">
        <input id="job-enabled" v-model="form.enabled" type="checkbox" />
        <label class="text-sm font-medium text-slate-700 dark:text-slate-300" for="job-enabled">Enabled</label>
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/scheduler"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? 'Saving...' : 'Save' }}
        </button>
      </div>
    </form>
  </div>
</template>
