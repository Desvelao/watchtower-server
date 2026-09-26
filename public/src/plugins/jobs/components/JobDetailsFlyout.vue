<script setup>
import { ref, watch } from 'vue';
import { useJobsStore } from '../../../stores/jobs';
import { getJob } from '../../../services/api/jobs';
import { getObservable } from '../../../services/api/observables';
import { getTask } from '../../../services/api/scheduler';
import { formatDate } from '../../../utils/date';
import AlertStatusBadge from '../../../components/AlertStatusBadge.vue';
import Flyout from '../../../components/common/Flyout.vue';
import CodeEditor from '../../../components/common/CodeEditor.vue';

const props = defineProps({
  jobId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useJobsStore();

const job = ref(null);
const refLabel = ref('');
const refProperties = ref(null);
const loading = ref(false);
const error = ref('');

// ref_id is polymorphic (see JobsListView.vue's own comment on
// jobs.from_scheduler) - resolved here the same lazy, one-off way, just
// scoped to whichever job the flyout is currently showing.
async function resolveRef(currentJob) {
  refLabel.value = `#${currentJob.ref_id}`;
  refProperties.value = null;
  if (!currentJob.ref_id) return;

  try {
    if (currentJob.from_scheduler) {
      const { item: task } = await getTask(currentJob.ref_id);
      if (task) refLabel.value = `${task.name} (${task.type})`;
    } else {
      const { observable } = await getObservable(currentJob.ref_id);
      if (observable) {
        refLabel.value = observable.name;
        refProperties.value = observable.properties || null;
      }
    }
  } catch (err) {
    // Keep the "#<id>" fallback label - the ref may no longer exist.
  }
}

watch(
  () => props.jobId,
  async (id) => {
    job.value = null;
    refLabel.value = '';
    refProperties.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      const resolved = cached || (await getJob(id).then((res) => res.item, () => null));
      job.value = resolved || null;
      if (!job.value) {
        error.value = 'Job not found.';
      } else {
        await resolveRef(job.value);
      }
    } catch (err) {
      error.value = 'Failed to load job details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!jobId" :title="`Job #${jobId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="job">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ job.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Type</td>
              <td class="py-1.5 capitalize">{{ job.type }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Ref</td>
              <td class="py-1.5">{{ refLabel }} <span class="text-xs text-slate-400 dark:text-slate-500">(ref_id: {{ job.ref_id }})</span></td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Worker</td>
              <td class="py-1.5">{{ job.worker_id || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Status</td>
              <td class="py-1.5"><AlertStatusBadge :status="job.status" /></td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Action</td>
              <td class="py-1.5 text-xs">{{ job.action || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Message</td>
              <td class="py-1.5 text-xs">{{ job.message || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Retries</td>
              <td class="py-1.5">{{ job.retries }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Taken at</td>
              <td class="py-1.5">{{ job.taken_at ? formatDate(job.taken_at) : '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Acked at</td>
              <td class="py-1.5">{{ job.acked_at ? formatDate(job.acked_at) : '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Last error</td>
              <td class="py-1.5" :class="job.error_at ? 'text-red-600 dark:text-red-400' : ''">
                {{ job.error_at ? formatDate(job.error_at) : '-' }}
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section v-if="job.result" class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Result</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(job.result, null, 2)" language="json" read-only min-height="8rem" />
        </div>
      </section>

      <section v-if="refProperties" class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Observable properties</h3>
        <div class="mt-2">
          <CodeEditor :model-value="JSON.stringify(refProperties, null, 2)" language="json" read-only min-height="8rem" />
        </div>
      </section>
    </template>
  </Flyout>
</template>
