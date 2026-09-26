<script setup>
import { ref, watch } from 'vue';
import { useRolesStore } from '../../../stores/roles';
import Flyout from '../../../components/common/Flyout.vue';

const props = defineProps({
  roleId: { type: [String, Number], default: null },
});

const emit = defineEmits(['close']);

const store = useRolesStore();

const role = ref(null);
const error = ref('');
watch(
  () => props.roleId,
  (id) => {
    role.value = null;
    error.value = '';
    if (!id) return;

    // Roles are few and unpaginated (see stores/roles.js) - there is no
    // GET /api/roles/:id route, so the already-loaded list is the only
    // source. If the row isn't in it, it doesn't exist (or was just
    // deleted elsewhere).
    const found = store.findById(id);
    if (found) {
      role.value = found;
    } else {
      error.value = 'Role not found.';
    }
  },
  { immediate: true },
);
</script>

<template>
  <Flyout :open="!!roleId" :title="`Role #${roleId}`" @close="emit('close')">
    <p v-if="error" class="mt-4 text-sm text-red-600 dark:text-red-400">{{ error }}</p>

    <template v-else-if="role">
      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Details</h3>
        <table class="mt-2 w-full text-sm">
          <tbody class="divide-y divide-slate-100 dark:divide-slate-700">
            <tr>
              <td class="w-40 py-1.5 pr-3 text-slate-500 dark:text-slate-400">ID</td>
              <td class="py-1.5">{{ role.id }}</td>
            </tr>
            <tr>
              <td class="py-1.5 pr-3 text-slate-500 dark:text-slate-400">Name</td>
              <td class="py-1.5">{{ role.name }}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="mt-4">
        <h3 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">Permissions</h3>
        <div class="mt-2 flex flex-wrap gap-1.5">
          <span
            v-for="permission in role.permissions || []"
            :key="permission"
            class="inline-block rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600 dark:bg-slate-700 dark:text-slate-300"
          >
            {{ permission }}
          </span>
          <span v-if="!role.permissions || role.permissions.length === 0" class="text-sm text-slate-400 dark:text-slate-500">-</span>
        </div>
      </section>
    </template>
  </Flyout>
</template>
