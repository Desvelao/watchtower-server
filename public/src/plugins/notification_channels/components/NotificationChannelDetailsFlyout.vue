<script setup>
import { ref, watch } from 'vue';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { getNotificationChannel } from '../../../services/api/notification_channels';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';

const props = defineProps({
  channelId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useNotificationChannelsStore();

const channel = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.channelId,
  async (id) => {
    channel.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        channel.value = cached;
      } else {
        const { item } = await getNotificationChannel(id);
        channel.value = item || null;
        if (!channel.value) error.value = 'Notification channel not found.';
      }
    } catch (err) {
      error.value = 'Failed to load notification channel details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!channelId" :title="`Channel #${channelId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="channel">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ channel.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ channel.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Type</td>
              <td class="py-1.5">{{ channel.type }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
              <td class="py-1.5">{{ formatDate(channel.created_at) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
              <td class="py-1.5">{{ formatDate(channel.updated_at) }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Options</h3>
        <div class="mt-2 space-y-1 text-sm text-slate-600 dark:text-slate-300">
          <template v-if="channel.type === 'discord'">
            <div>URL: <a :href="channel.options?.url" target="_blank" rel="noopener noreferrer" class="underline hover:text-slate-900 dark:hover:text-slate-100">{{ channel.options?.url }}</a></div>
            <div>Message: {{ channel.options?.message }}</div>
          </template>
          <template v-else-if="channel.type === 'webhook'">
            <div>URL: <a :href="channel.options?.url" target="_blank" rel="noopener noreferrer" class="underline hover:text-slate-900 dark:hover:text-slate-100">{{ channel.options?.url }}</a></div>
            <div>Method: {{ channel.options?.method }}</div>
            <div>Body: <span class="font-mono text-xs">{{ channel.options?.body || '-' }}</span></div>
            <div>Headers: <span class="font-mono text-xs">{{ channel.options?.headers || '-' }}</span></div>
          </template>
          <template v-else>
            <div class="text-slate-400 dark:text-slate-500">No details available.</div>
          </template>
        </div>
      </section>
    </template>
  </Flyout>
</template>
