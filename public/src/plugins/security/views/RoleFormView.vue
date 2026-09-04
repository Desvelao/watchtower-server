<script setup>
import { computed, onMounted, reactive, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useRolesStore } from "../../../stores/roles";
import { HTTPError } from "../../../services/api/http";
import PermissionPicker from "../../../components/common/PermissionPicker.vue";
import { PERMISSIONS } from "../../../constants/permissions";

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useRolesStore();

const roleId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!roleId.value);

// An admin assigns from every permission the app knows about, regardless
// of their own current role - unlike ApiKeysView.vue's picker, which is
// intentionally limited to the caller's own current permissions.
const ALL_PERMISSIONS = Object.values(PERMISSIONS);

const form = reactive({
  name: "",
  permissions: [],
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref("");

onMounted(async () => {
  if (!isEdit.value) return;

  if (!store.items.length) await store.fetchList();
  const existing = store.findById(roleId.value);
  if (existing) {
    form.name = existing.name;
    form.permissions = [...(existing.permissions || [])];
  } else {
    error.value = "Role not found.";
  }
  loading.value = false;
});

async function onSubmit() {
  error.value = "";
  saving.value = true;
  try {
    const payload = { name: form.name, permissions: form.permissions };
    if (isEdit.value) {
      await store.update(roleId.value, payload);
    } else {
      await store.create(payload);
    }
    router.push('/roles');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.error || body?.errors?.join(", ") || body?.message || "Save failed";
    } else {
      error.value = "Save failed";
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="max-w-2xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit role #${roleId}` : "New role" }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label for="role-name" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Name</label>
        <input
          id="role-name"
          v-model="form.name"
          type="text"
          required
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div>
        <span class="block text-sm font-medium text-slate-700 dark:text-slate-300">Permissions</span>
        <div class="mt-1.5">
          <PermissionPicker v-model="form.permissions" :available-permissions="ALL_PERMISSIONS" />
        </div>
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/roles"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? "Saving..." : "Save" }}
        </button>
      </div>
    </form>
  </div>
</template>
