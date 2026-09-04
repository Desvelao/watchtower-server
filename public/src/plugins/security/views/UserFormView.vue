<script setup>
import { computed, onMounted, reactive, ref } from "vue";
import { useRoute, useRouter } from "vue-router";
import { useUsersStore } from "../../../stores/users";
import { useRolesStore } from "../../../stores/roles";
import { listUsers } from "../../../services/api/users";
import { HTTPError } from "../../../services/api/http";
import ResetPasswordDialog from "../../../components/common/ResetPasswordDialog.vue";

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useUsersStore();
const rolesStore = useRolesStore();

const userId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!userId.value);

const form = reactive({
  username: "",
  password: "",
  role_id: "",
  enabled: true,
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref("");
const resetPasswordOpen = ref(false);

onMounted(async () => {
  if (!rolesStore.items.length) await rolesStore.fetchList();

  if (!isEdit.value) {
    if (rolesStore.items.length) form.role_id = String(rolesStore.items[0].id);
    loading.value = false;
    return;
  }

  const cached = store.findById(userId.value);
  if (cached) {
    form.username = cached.username;
    form.role_id = String(cached.role_id);
    form.enabled = cached.enabled;
    loading.value = false;
    return;
  }

  try {
    const { items } = await listUsers({ id: userId.value });
    if (items && items[0]) {
      form.username = items[0].username;
      form.role_id = String(items[0].role_id);
      form.enabled = items[0].enabled;
    } else {
      error.value = "User not found.";
    }
  } catch (err) {
    error.value = "Failed to load user.";
  } finally {
    loading.value = false;
  }
});

function toRequestBody() {
  const body = {
    username: form.username,
    role_id: Number(form.role_id),
  };
  if (isEdit.value) {
    body.enabled = form.enabled;
  } else {
    body.password = form.password;
  }
  return body;
}

async function onSubmit() {
  error.value = "";
  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(userId.value, toRequestBody());
    } else {
      await store.create(toRequestBody());
    }
    router.push('/users');
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

async function onResetPassword(password) {
  await store.resetPassword(userId.value, password);
}
</script>

<template>
  <div class="max-w-md">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit user #${userId}` : "New user" }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label for="user-username" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Username</label>
        <input
          id="user-username"
          v-model="form.username"
          type="text"
          required
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div v-if="!isEdit">
        <label for="user-password" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Initial password</label>
        <input
          id="user-password"
          v-model="form.password"
          type="password"
          required
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div>
        <label for="user-role" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Role</label>
        <select
          id="user-role"
          v-model="form.role_id"
          required
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option v-for="role in rolesStore.items" :key="role.id" :value="String(role.id)">{{ role.name }}</option>
        </select>
      </div>

      <div v-if="isEdit" class="flex items-center gap-2">
        <input id="user-enabled" v-model="form.enabled" type="checkbox" />
        <label for="user-enabled" class="text-sm font-medium text-slate-700 dark:text-slate-300">Enabled</label>
      </div>

      <div v-if="isEdit">
        <button
          type="button"
          class="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="resetPasswordOpen = true"
        >
          Reset Password
        </button>
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/users"
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

    <ResetPasswordDialog
      :open="resetPasswordOpen"
      :on-submit="onResetPassword"
      @close="resetPasswordOpen = false"
    />
  </div>
</template>
