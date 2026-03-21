<script setup>
const props = defineProps({
  title: {
    type: String,
    required: true,
  },
  component: {
    type: [String, Object],
    required: true,
  },
  componentProps: {
    type: Object,
    default: () => ({}),
  },
});
</script>

<style scoped>
.panel-container {
  border: 1px solid #ddd;
  border-radius: 8px;
  padding: 16px;
  background-color: #f9f9f9;
  display: flex;
  justify-content: center;
}
.panel-container > * {
  flex: 0 0 auto;
}
.panel-header {
  margin-bottom: 16px;
}
.panel-title {
  font-size: 1.2rem;
  font-weight: bold;
  text-align: center;
}
.panel-body {
  padding: 8px;
}
</style>

<template>
  <div class="panel-container">
    <div>
      <div class="panel-header">
        <slot name="header">
          <h2 class="panel-title">{{ title }}</h2>
        </slot>
      </div>
      <div class="panel-body">
        <component
          v-if="component"
          :is="component"
          v-bind="componentProps"
          v-on="$listeners"
        ></component>
        <slot v-else></slot>
      </div>
    </div>
  </div>
</template>
