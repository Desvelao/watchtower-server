<script setup>
import { ref, watch } from 'vue';
import { useSchedulerStore } from '../../../stores/scheduler';
import { getTask } from '../../../services/api/scheduler';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';

const props = defineProps({
  taskId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useSchedulerStore();

const task = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.taskId,
  async (id) => {
    task.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        task.value = cached;
      } else {
        const { item } = await getTask(id);
        task.value = item || null;
        if (!task.value) error.value = 'Scheduler task not found.';
      }
    } catch (err) {
      error.value = 'Failed to load scheduler task details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!taskId" :title="`Scheduler task #${taskId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="task">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ task.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ task.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Type</td>
              <td class="py-1.5 capitalize">{{ task.type }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Observable type</td>
              <td class="py-1.5">{{ task.observable_type_id || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Schedule</td>
              <td class="py-1.5">
                <span v-if="task.schedule_type === 'cron'" class="font-mono text-xs">{{ task.cron_expression }}</span>
                <span v-else>One-shot @ {{ formatDate(task.run_at) }}</span>
              </td>
            </tr>
            <tr v-if="task.type === 'observe' || task.type === 'analyze'">
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Observable IDs</td>
              <td class="py-1.5">
                <span v-if="task.observable_ids && task.observable_ids.length">{{ task.observable_ids.join(', ') }}</span>
                <span v-else class="text-slate-400 dark:text-slate-500">All enabled observables</span>
              </td>
            </tr>
            <tr v-if="task.type === 'notify'">
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Notify policy IDs</td>
              <td class="py-1.5">
                <span v-if="task.notify_policy_ids && task.notify_policy_ids.length">{{ task.notify_policy_ids.join(', ') }}</span>
                <span v-else class="text-slate-400 dark:text-slate-500">All enabled policies</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Enabled</td>
              <td class="py-1.5">{{ task.enabled ? 'Enabled' : 'Disabled' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Next run</td>
              <td class="py-1.5">{{ task.next_run_at ? formatDate(task.next_run_at) : '—' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Last run</td>
              <td class="py-1.5">{{ task.last_run_at ? formatDate(task.last_run_at) : 'Never' }}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </template>
  </Flyout>
</template>
