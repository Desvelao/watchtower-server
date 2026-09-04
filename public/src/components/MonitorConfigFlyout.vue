<script setup>
import { computed } from "vue";
import CodeEditor from "./common/CodeEditor.vue";

const props = defineProps({
  open: { type: Boolean, default: false },
  config: { type: String, default: null },
  monitorId: { type: String, default: "" },
});

const emit = defineEmits(["close"]);

// `config` is opaque, worker-reported text (see worker_config_report.lua) -
// never enforced/validated server-side, so this must never throw if it
// somehow isn't valid JSON. Falls back to showing the raw string as plain
// text instead.
const prettyConfig = computed(() => {
  if (!props.config) return "";
  try {
    return JSON.stringify(JSON.parse(props.config), null, 2);
  } catch (err) {
    return props.config;
  }
});

const configLanguage = computed(() => {
  if (!props.config) return "text";
  try {
    JSON.parse(props.config);
    return "json";
  } catch (err) {
    return "text";
  }
});
</script>

<template>
  <div
    v-if="open"
    class="fixed inset-0 z-50 flex justify-end bg-slate-900/40"
    @click.self="emit('close')"
  >
    <div class="h-full w-full max-w-2xl overflow-y-auto bg-white p-5 shadow-xl dark:bg-slate-800">
      <div class="flex items-center justify-between">
        <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">Config — {{ monitorId }}</h2>
        <button
          type="button"
          title="Close"
          aria-label="Close"
          class="rounded p-1.5 text-slate-500 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          @click="emit('close')"
        >
          ✕
        </button>
      </div>

      <div class="mt-4">
        <CodeEditor :model-value="prettyConfig" :language="configLanguage" read-only min-height="70vh" />
      </div>
    </div>
  </div>
</template>
