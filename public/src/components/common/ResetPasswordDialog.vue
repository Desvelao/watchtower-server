<script setup>
import { onMounted, onUnmounted, ref, watch } from "vue";
import { HTTPError } from "../../services/api/http";

const props = defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, default: "Reset password" },
  onSubmit: { type: Function, required: true },
});

const emit = defineEmits(["close"]);

const password = ref("");
const saving = ref(false);
const error = ref("");

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      password.value = "";
      error.value = "";
    }
  }
);

function onKeydown(event) {
  if (event.key === "Escape" && props.open) {
    emit("close");
  }
}
onMounted(() => document.addEventListener("keydown", onKeydown));
onUnmounted(() => document.removeEventListener("keydown", onKeydown));

async function submit() {
  if (!password.value) return;
  error.value = "";
  saving.value = true;
  try {
    await props.onSubmit(password.value);
    emit("close");
  } catch (err) {
    error.value = err instanceof HTTPError ? err.response.body?.message || "Failed to reset password." : "Failed to reset password.";
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div
    v-if="open"
    role="dialog"
    aria-modal="true"
    :aria-label="title"
    class="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4"
    @click.self="emit('close')"
  >
    <div class="w-full max-w-sm rounded-lg bg-white p-5 shadow-xl dark:bg-slate-800">
      <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">{{ title }}</h2>
      <form class="mt-3" @submit.prevent="submit">
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300">New password</label>
        <input
          v-model="password"
          type="password"
          required
          autofocus
          class="mt-1 w-full rounded border border-slate-300 px-3 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <p v-if="error" class="mt-2 text-sm text-red-600 dark:text-red-400">{{ error }}</p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
            @click="emit('close')"
          >
            Cancel
          </button>
          <button
            type="submit"
            :disabled="saving || !password"
            class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
          >
            {{ saving ? "Saving..." : "Reset password" }}
          </button>
        </div>
      </form>
    </div>
  </div>
</template>
