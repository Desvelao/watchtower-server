<script setup>
import { computed, ref } from 'vue';
import CodeEditor from '../../../components/common/CodeEditor.vue';

const props = defineProps({
  result: { type: Object, default: null },
});

const showRaw = ref(false);

const ok = computed(() => !!props.result?.ok);
const dataJson = computed(() => JSON.stringify(props.result?.data ?? null, null, 2));
const rawJson = computed(() => JSON.stringify(props.result ?? null, null, 2));
</script>

<template>
  <div>
    <span
      class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium"
      :class="
        ok
          ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
          : 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300'
      "
    >
      {{ ok ? 'Success' : 'Failed' }}
    </span>

    <CodeEditor :model-value="dataJson" language="json" :read-only="true" min-height="10rem" class="mt-2" />

    <button
      type="button"
      class="mt-2 text-xs font-medium text-slate-500 underline hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      @click="showRaw = !showRaw"
    >
      {{ showRaw ? 'Hide raw response' : 'Show raw response' }}
    </button>
    <CodeEditor v-if="showRaw" :model-value="rawJson" language="json" :read-only="true" min-height="10rem" class="mt-2" />
  </div>
</template>
