<script setup>
const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
  action: {
    type: Object,
    required: true,
  },
});

const validation = defineModel('validation');

const { isRunning, data } = props.action;
</script>

<template>
  <v-form v-model="validation">
    <v-container>
      <div>
        <div class="d-flex justify-between">
          <v-spacer></v-spacer>
          <v-icon-btn
            icon="mdi-test-tube"
            size="24"
            color="primary"
            title="Test"
            @click="action.run"
            :disabled="isRunning || !validation"
          >
            <v-icon size="24"></v-icon>
          </v-icon-btn>
        </div>
        <div>
          <v-text-field
            v-model="record.test_url"
            density="compact"
            label="Test URL"
            variant="plain"
            rounded
          ></v-text-field>
        </div>
        <div>
          <div>Scrap:</div>
          <code>{{ JSON.stringify(data) }}</code>
        </div>
      </div>
    </v-container>
  </v-form>
</template>
