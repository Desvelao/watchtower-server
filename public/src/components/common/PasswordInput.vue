<script setup>
import { ref } from "vue";
import IconEye from "./icons/IconEye.vue";
import IconEyeOff from "./icons/IconEyeOff.vue";

// Password <input> with a show/hide toggle. Attributes (id, required,
// autocomplete, placeholder, disabled, class, ...) go to the <input> itself;
// `wrapperClass` styles the outer element (e.g. width in a flex row).
defineOptions({ inheritAttrs: false });

defineProps({
  modelValue: { type: String, default: "" },
  wrapperClass: { type: [String, Array, Object], default: "" },
});

const emit = defineEmits(["update:modelValue"]);

const visible = ref(false);
</script>

<template>
  <div class="relative" :class="wrapperClass">
    <input
      v-bind="$attrs"
      :value="modelValue"
      :type="visible ? 'text' : 'password'"
      class="pr-9"
      @input="emit('update:modelValue', $event.target.value)"
    />
    <button
      type="button"
      class="absolute inset-y-0 right-0 flex items-center px-2.5 text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      :aria-label="visible ? 'Hide password' : 'Show password'"
      :aria-pressed="visible"
      @click="visible = !visible"
    >
      <IconEyeOff v-if="visible" class="h-4 w-4" />
      <IconEye v-else class="h-4 w-4" />
    </button>
  </div>
</template>
