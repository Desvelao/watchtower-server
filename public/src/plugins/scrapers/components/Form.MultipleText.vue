<script setup>
import ActivatorFlyout from '../../../components/common/Activator.Flyout.vue';

const data = defineModel();
const props = defineProps({
  new_element: {
    type: String,
    default: '',
  },
  label: {
    type: String,
  },
  validate: {
    type: Array,
  },
});

function addNewElement() {
  data.value.push(props.new_element);
}

function removeItem(index) {
  data.value.splice(index, 1);
}
</script>

<template>
  <div class="d-flex justify-between">
    <div v-if="label" style="margin-right: 8px">
      <div>{{ label }}</div>
    </div>
    <div>
      <v-icon-btn
        type="button"
        icon="mdi-plus"
        size="24"
        color="primary"
        title="Add"
        @click="addNewElement"
      >
        <v-icon size="24"></v-icon>
      </v-icon-btn>
    </div>
    <div>
      <ActivatorFlyout>
        <template v-slot:activator="{ toggle }">
          <v-icon-btn
            type="button"
            icon="mdi-help-circle-outline"
            size="24"
            color="primary"
            title="Help"
            @click="toggle"
          >
            <v-icon size="24"></v-icon>
          </v-icon-btn>
        </template>
        <template v-slot:title>
          <span class="text-h5">Info</span>
        </template>
        <template v-slot:body>
          <slot name="body" :close="close"></slot>
        </template>
      </ActivatorFlyout>
    </div>
  </div>
  <div style="margin-bottom: 20px"></div>
  <div v-for="(selector, index) in data" class="d-flex justify-between">
    <v-text-field
      :rules="validate"
      v-model="data[index]"
      density="compact"
      :label="props.label"
      variant="plain"
      rounded
    ></v-text-field>
    <v-icon-btn
      v-if="data.length > 1"
      icon="mdi-delete-outline"
      color="error"
      size="18"
      title="Remove"
      @click="removeItem(index)"
    >
      <v-icon size="18"></v-icon>
    </v-icon-btn>
  </div>
</template>
