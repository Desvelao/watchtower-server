<script setup>
import { ref, watch } from 'vue';
import { useRulesStore } from '../../../stores/rules';
import { getRule } from '../../../services/api/rules';
import { formatDate } from '../../../utils/date';
import AlertSeverityBadge from '../../../components/AlertSeverityBadge.vue';
import Flyout from '../../../components/common/Flyout.vue';

const props = defineProps({
  ruleId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useRulesStore();

const rule = ref(null);
const loading = ref(false);
const error = ref('');
watch(
  () => props.ruleId,
  async (id) => {
    rule.value = null;
    error.value = '';
    if (!id) return;

    loading.value = true;
    try {
      const cached = store.findById(id);
      if (cached) {
        rule.value = cached;
      } else {
        const { item } = await getRule(id);
        rule.value = item || null;
        if (!rule.value) error.value = 'Rule not found.';
      }
    } catch (err) {
      error.value = 'Failed to load rule details.';
    } finally {
      loading.value = false;
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!ruleId" :title="`Rule #${ruleId}`" @close="emit('close')">
    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>
    <p v-else-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="rule">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ rule.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ rule.name }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Description</td>
              <td class="py-1.5">{{ rule.description || '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Severity</td>
              <td class="py-1.5">
                <AlertSeverityBadge v-if="rule.severity" :severity="rule.severity" />
                <span v-else>-</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Condition</td>
              <td class="py-1.5">
                <span class="font-mono text-xs">{{ rule.condition_expression }}</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Tags</td>
              <td class="py-1.5">
                <span
                  v-for="tag in rule.tags || []"
                  :key="tag"
                  class="mr-1 inline-block rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 dark:bg-slate-700 dark:text-slate-300"
                >
                  {{ tag }}
                </span>
                <span v-if="!rule.tags || rule.tags.length === 0" class="text-slate-400 dark:text-slate-500">-</span>
              </td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Cooldown</td>
              <td class="py-1.5">{{ rule.cooldown_seconds != null ? `${rule.cooldown_seconds}s` : '-' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Enabled</td>
              <td class="py-1.5">{{ rule.enabled ? 'Enabled' : 'Disabled' }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Created</td>
              <td class="py-1.5">{{ formatDate(rule.created_at) }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Updated</td>
              <td class="py-1.5">{{ formatDate(rule.updated_at) }}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </template>
  </Flyout>
</template>
