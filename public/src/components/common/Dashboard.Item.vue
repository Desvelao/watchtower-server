<template>
  <div class="dashboard-item" :style="{ gridColumn: `span ${span}` }">
    <slot />
  </div>
</template>

<script setup>
import { defineProps } from 'vue';

// Define props using Composition API
const props = defineProps({
  span: {
    type: Number,
    default: 4,
  },
});

// Destructure if you want direct access
const { span } = props;
</script>

<style scoped>
.dashboard-item {
  /* background: #f5f5f5; */
  /* padding: 16px; */
  border-radius: 8px;
}
</style>
