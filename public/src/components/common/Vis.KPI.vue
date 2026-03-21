<script setup>
import { ref, watch } from 'vue';
import { useAsyncAction } from '../../hooks/useAction';
import VisPanel from './Vis.Panel.vue';

const props = defineProps({
  fetch: {
    type: Function,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  label: {
    type: String,
    required: true,
  },
  refetch: {
    type: Number,
    default: 0,
  },
});

const action = useAsyncAction(props.fetch, {
  data: null,
});

const { isRunning, data, error, run } = action;

function refresh() {
  run();
}

// Watch for changes in props.myProp
watch(
  () => props.refetch,
  (newValue, oldValue) => {
    refresh();
  },
);

run();
</script>

<style scoped>
.green {
  font-size: 2rem; /* Adjust size as needed */
  color: #2ad154; /* Minimal color, adjust as needed */
  font-weight: bold;
  text-align: center;
}
.label {
  font-weight: bold;
  font-style: italic;
  text-align: center;
}
</style>

<template>
  <vis-panel :title="title">
    <template v-slot>
      <div class="d-flex align-center">
        <div style="text-align: center">
          <div class="my-2">
            <v-progress-linear
              v-if="isRunning"
              indeterminate
              color="primary"
            ></v-progress-linear>
            <v-alert v-if="error" type="error" variant="outlined" dense>
              Error: {{ error.message }}
            </v-alert>
            <div v-if="data !== null" :class="`my-2 green`">{{ data }}</div>
          </div>
          <div class="label">{{ label }}</div>
        </div>
      </div>
    </template>
  </vis-panel>
</template>
