<script setup>
import SchemaDrivenField from './SchemaDrivenField.vue';

const props = defineProps({
  schema: { type: Array, required: true },
  modelValue: { type: Object, required: true },
});

const emit = defineEmits(['update:modelValue']);

function onFieldUpdate(name, value) {
  emit('update:modelValue', { ...props.modelValue, [name]: value });
}
</script>

<template>
  <div class="space-y-4">
    <SchemaDrivenField
      v-for="definition in schema"
      :key="definition.name"
      :definition="definition"
      :model-value="modelValue[definition.name]"
      @update:model-value="(value) => onFieldUpdate(definition.name, value)"
    />
  </div>
</template>
