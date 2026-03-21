<script setup>
import ActivatorFlyout from '../common/Activator.Flyout.vue';

defineProps({
  item: {
    type: Object,
    required: true,
  },
});
</script>
<template>
  <ActivatorFlyout>
    <template v-slot:activator="{ toggle }">
      <span :onClick="toggle" style="cursor: pointer">{{ item.name }}</span>
    </template>
    <template v-slot:title
      ><span class="text-h5"
        >Item details: {{ item.name }} ({{ item.id }})
      </span></template
    >
    <template v-slot:body>
      <div>Name: {{ item.name }}</div>
      <div>
        URL:
        <a :href="item.url" target="_blank" rel="noopener noreferrer">link</a>
      </div>
      <div>Created at: {{ item.created_at }}</div>
      <div>Updated at: {{ item.updated_at }}</div>
    </template>
  </ActivatorFlyout>
</template>
