<script setup>
import { onMounted, ref, watch } from 'vue';
import { useNotificationPoliciesStore } from '../../../stores/notificationPolicies';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { getPolicy } from '../../../services/api/notification_policies';
import { formatDate } from '../../../utils/date';
import Flyout from '../../../components/common/Flyout.vue';

const props = defineProps({
  policyId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useNotificationPoliciesStore();
const channelsStore = useNotificationChannelsStore();

onMounted(() => {
  if (!channelsStore.items.length) channelsStore.fetchList();
});

function channelName(id) {
  const channel = channelsStore.items.find((c) => c.id === id);
  return channel ? channel.name : `#${id}`;
}

const policy = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.policyId,
  async (id) => {
    policy.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        policy.value = cached;
      } else {
        const { item } = await getPolicy(id);
        policy.value = item || null;
        if (!policy.value) error.value = 'Notification policy not found.';
      }
    } catch (err) {
      error.value = 'Failed to load notification policy details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!policyId" :title="`Policy #${policyId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="policy">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ policy.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ policy.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Condition</td>
              <td class="py-1.5">
                <span class="font-mono text-xs">{{ policy.condition_expression }}</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Channels</td>
              <td class="py-1.5">
                <span
                  v-for="id in policy.channel_ids || []"
                  :key="id"
                  class="mr-1 inline-block rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 dark:bg-slate-700 dark:text-slate-300"
                >
                  {{ channelName(id) }}
                </span>
                <span v-if="!policy.channel_ids || policy.channel_ids.length === 0" class="text-slate-400 dark:text-slate-500">-</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Enabled</td>
              <td class="py-1.5">{{ policy.enabled ? 'Enabled' : 'Disabled' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
              <td class="py-1.5">{{ formatDate(policy.created_at) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
              <td class="py-1.5">{{ formatDate(policy.updated_at) }}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </template>
  </Flyout>
</template>
