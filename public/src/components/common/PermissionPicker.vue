<script setup>
import { computed } from "vue";

const props = defineProps({
  modelValue: { type: Array, required: true },
  availablePermissions: { type: Array, required: true },
});
const emit = defineEmits(["update:modelValue"]);

const groupedPermissions = computed(() => {
  const groups = [];
  const byCategory = new Map();
  for (const perm of props.availablePermissions) {
    const category = perm.split(":")[0];
    if (!byCategory.has(category)) {
      const group = { category, perms: [] };
      byCategory.set(category, group);
      groups.push(group);
    }
    byCategory.get(category).perms.push(perm);
  }
  return groups;
});

function formatCategoryLabel(category) {
  if (category === "api_key") return "API Key";
  return category.charAt(0).toUpperCase() + category.slice(1);
}

function isCategoryFullySelected(perms) {
  return perms.every((p) => props.modelValue.includes(p));
}

function isCategoryPartiallySelected(perms) {
  return !isCategoryFullySelected(perms) && perms.some((p) => props.modelValue.includes(p));
}

function toggleCategory(perms, checked) {
  const next = checked
    ? Array.from(new Set([...props.modelValue, ...perms]))
    : props.modelValue.filter((p) => !perms.includes(p));
  emit("update:modelValue", next);
}

function togglePermission(perm, checked) {
  const next = checked
    ? Array.from(new Set([...props.modelValue, perm]))
    : props.modelValue.filter((p) => p !== perm);
  emit("update:modelValue", next);
}

const vIndeterminate = {
  mounted(el, binding) {
    el.indeterminate = binding.value;
  },
  updated(el, binding) {
    el.indeterminate = binding.value;
  },
};
</script>

<template>
  <div class="space-y-2">
    <div
      v-for="group in groupedPermissions"
      :key="group.category"
      class="rounded border border-slate-200 p-2 dark:border-slate-700"
    >
      <label class="flex items-center gap-1.5 text-sm font-medium text-slate-700 dark:text-slate-300">
        <input
          type="checkbox"
          :checked="isCategoryFullySelected(group.perms)"
          v-indeterminate="isCategoryPartiallySelected(group.perms)"
          :disabled="group.perms.length < 2"
          @change="toggleCategory(group.perms, $event.target.checked)"
        />
        {{ formatCategoryLabel(group.category) }}
      </label>
      <div class="mt-1 ml-5 flex flex-wrap gap-x-4 gap-y-1.5">
        <label
          v-for="perm in group.perms"
          :key="perm"
          class="flex items-center gap-1.5 text-sm text-slate-700 dark:text-slate-300"
        >
          <input
            type="checkbox"
            :checked="modelValue.includes(perm)"
            @change="togglePermission(perm, $event.target.checked)"
          />
          {{ perm }}
        </label>
      </div>
    </div>
  </div>
</template>
