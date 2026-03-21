<script setup>
import { onMounted } from 'vue';
import { useAsyncAction } from '../../../hooks/useAction';
import { APINotificationChannels, APIProducts } from '../../../services/api';
import { validate } from '../../../services/form';

const record = defineModel();
const validForm = defineModel('validation');
const actionNotificationChannels = useAsyncAction(
  async search => {
    return await APINotificationChannels.getList({ search }).then(
      ({ body: { items } }) =>
        items.map(({ name, id }) => ({ title: name, value: id })),
    );
  },
  { data: [] },
);

const { data: notificationChannels } = actionNotificationChannels;

const actionItems = useAsyncAction(
  async search => {
    return await APIProducts.getList({ search }).then(({ body: { items } }) =>
      items.map(({ name, id }) => ({ title: name, value: id })),
    );
  },
  { data: [] },
);

const { data: items } = actionItems;

const formNameRules = [
  validate.isRequired('Name'),
  validate.stringHasMaxChars(20, 'Name'),
];

const formChannelsRules = [
  validate.isRequired('Channel'),
  value => (value.length ? true : 'Select at least some channel'),
];

const formItem = [
  validate.isRequired('Item'),
  value => value || 'Select at least an alert',
];

onMounted(() => {
  actionNotificationChannels.run();
  actionItems.run();
});

function createDelayedRequest(fn, time = 500) {
  let timer = undefined;
  return function (...params) {
    if (timer) {
      clearTimeout(timer);
    }
    timer = setTimeout(() => fn(...params), time);
  };
}

const searchChannels = createDelayedRequest((...params) =>
  actionNotificationChannels.run(...params),
);

const searchItems = createDelayedRequest((...params) =>
  actionItems.run(...params),
);
</script>

<template>
  <v-form v-model="validForm">
    <v-container>
      <v-row>
        <v-col cols="12" md="6">
          <v-text-field
            v-model="record.name"
            :rules="formNameRules"
            density="compact"
            label="Name"
            variant="plain"
            rounded
          ></v-text-field>
        </v-col>
        <v-col cols="12" md="6">
          <v-checkbox v-model="record.enabled" label="Enabled"></v-checkbox>
        </v-col>
      </v-row>
      <v-combobox
        v-model="record.alert"
        :rules="formItem"
        :items="items"
        label="Item"
        chips
        @update:search="searchItems"
      ></v-combobox>

      <v-combobox
        v-model="record.channels"
        :rules="formChannelsRules"
        :items="notificationChannels"
        label="Notification channels"
        chips
        multiple
        @update:search="searchChannels"
      ></v-combobox>

      <v-row>
        <v-col cols="12" md="12">
          <v-text-field
            v-model="record.trigger_on_price"
            :rules="formNameRules"
            density="compact"
            label="Price condition"
            variant="plain"
            rounded
          ></v-text-field>
        </v-col>
      </v-row>

      <v-row>
        <v-col cols="12" md="6">
          <v-checkbox
            v-model="record.trigger_on_discount"
            label="On discount"
          ></v-checkbox>
        </v-col>
        <v-col cols="12" md="6">
          <v-checkbox
            v-model="record.trigger_on_available"
            label="On available"
          ></v-checkbox>
        </v-col>
      </v-row>
    </v-container>
  </v-form>
</template>
