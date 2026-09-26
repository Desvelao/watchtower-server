<script setup>
import { computed } from "vue";
import CodeEditor from "./common/CodeEditor.vue";
import Flyout from "./common/Flyout.vue";

const props = defineProps({
  open: { type: Boolean, default: false },
  config: { type: String, default: null },
  workerId: { type: String, default: "" },
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
  <Flyout :open="open" :title="`Config — ${workerId}`" max-width-class="max-w-2xl" @close="emit('close')">
    <div class="mt-4">
      <CodeEditor :model-value="prettyConfig" :language="configLanguage" read-only min-height="70vh" />
    </div>
  </Flyout>
</template>
