<template>
  <v-container>
    <div class="dashboard">
      <slot />
    </div>
  </v-container>
</template>

<script setup>
// No need for export default or defineComponent here
</script>

<style scoped>
.dashboard {
  display: grid;
  grid-template-columns: repeat(12, 1fr); /* 12-column grid */
  gap: 16px;
}
</style>
