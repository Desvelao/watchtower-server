<script setup>
defineProps({
  title: {
    type: String,
  },
  close: {
    type: Function,
    required: true,
  },
});
</script>

<template>
  <div class="app-container">
    <!-- The transition adds a slide animation -->
    <transition name="slide">
      <!-- The flyout element, which only renders when flyoutVisible is true -->
      <div class="flyout">
        <!-- A close button inside the flyout -->
        <div class="flyout-title">
          <div v-if="title">{{ title }}</div>
          <div v-if="!title"><slot name="title" :close="close"></slot></div>
          <div><button class="close-button" @click="close">×</button></div>
        </div>
        <v-divider></v-divider>
        <div class="flyout-content">
          <slot name="body" :close="close"></slot>
        </div>
      </div>
    </transition>
  </div>
</template>

<style scoped>
.app-container {
  position: relative;
  overflow: hidden;
}

.flyout-title {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

/* Style for the toggle button */
.toggle-button {
  margin: 20px;
  padding: 10px 20px;
  font-size: 16px;
}

/* The flyout panel is fixed at the right of the page */
.flyout {
  position: fixed;
  top: 0;
  right: 0;
  width: 600px;
  height: 100vh;
  background-color: #f9f9f9;
  box-shadow: -3px 0 5px rgba(0, 0, 0, 0.2);
  padding: 20px;
  box-sizing: border-box;
  z-index: 2000;
}

/* Padding to prevent the close button overlapping content */
.flyout-content {
  margin-top: 10px;
}

/* Simple styling for the close button */
.close-button {
  /* position: absolute;
  top: 10px;
  left: 10px; */
  background: none;
  border: none;
  font-size: 24px;
  cursor: pointer;
}

/* Transition Classes for the slide effect */
.slide-enter-active,
.slide-leave-active {
  transition: transform 0.3s ease;
}
.slide-enter-from,
.slide-leave-to {
  transform: translateX(100%);
}
</style>
