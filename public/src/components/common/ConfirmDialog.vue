<script setup>
import { onMounted, onUnmounted, watch } from "vue";

const props = defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: "Are you sure?" },
  message: { type: String, default: "" },
  confirmLabel: { type: String, default: "Confirm" },
});

const emit = defineEmits(["confirm", "cancel"]);

function onKeydown(event) {
  if (event.key === "Escape" && props.open) {
    emit("cancel");
  }
}

// Listener lives for the component's whole lifetime (not just while open)
// since `open` is a prop the parent toggles, not local state this
// component mounts/unmounts around - the keydown check above already
// gates on `props.open` so this is a no-op while closed.
onMounted(() => document.addEventListener("keydown", onKeydown));
onUnmounted(() => document.removeEventListener("keydown", onKeydown));
</script>

<template>
  <div
    v-if="open"
    role="dialog"
    aria-modal="true"
    :aria-label="title"
    class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4"
    @click.self="emit('cancel')"
  >
    <div class="w-full max-w-sm rounded-lg bg-white p-5 shadow-xl dark:bg-slate-800">
      <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">{{ title }}</h2>
      <p v-if="message" class="mt-2 text-sm text-slate-600 dark:text-slate-400">{{ message }}</p>
      <div class="mt-5 flex justify-end gap-2">
        <button
          type="button"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="emit('cancel')"
        >
          Cancel
        </button>
        <button
          type="button"
          class="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 dark:bg-red-500 dark:hover:bg-red-600"
          @click="emit('confirm')"
        >
          {{ confirmLabel }}
        </button>
      </div>
    </div>
  </div>
</template>
