<script setup>
import { ref } from 'vue';
import InfoMonitor from '../../../components/InfoMonitor.vue';
import { validate } from '../../../services/form';

const record = defineModel();
const validForm = defineModel('validation');

const formNameRules = [
  validate.isRequired('Name'),
  validate.stringHasMaxChars(20, 'Name'),
];

const formTypeRules = [
  validate.isRequired('Type'),
  validate.isOneOf(['discord', 'webhook']),
];

const formOptionsDiscordURLRules = [
  validate.isRequired('Discord webhook URL'),
  // validate.stringMatchRegex(/^https:\/\/discord\.com\/api\/webhooks\/\d+\/[a-zA-Z0-9_-]+$/, 'Discord webhook URL not valid')
];

const formOptionsDiscordMessageRules = [
  validate.isRequired('Discord message'),
  validate.stringHasMaxChars(255, 'Message'),
];

const allowedWebhookMethods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];
const formOptionsWebhookMethod = [
  validate.isRequired('Method'),
  validate.isOneOf(allowedWebhookMethods),
];

// LUA validation
// function isValidDiscordWebhook(url)
//     local pattern = "^https://discord%.com/api/webhooks/%d+/%w+$"
//     return url:match(pattern) ~= nil
// end
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
          <v-select
            v-model="record.type"
            :rules="formTypeRules"
            label="Select"
            :items="['discord', 'webhook']"
          ></v-select>
        </v-col>
      </v-row>
      <div v-if="record.type === 'discord'">
        <div>Discord options:</div>
        <div class="mb-4">
          <InfoMonitor />
        </div>
        <v-text-field
          v-model="record.options_discord.url"
          :rules="formOptionsDiscordURLRules"
          density="compact"
          label="URL"
          variant="plain"
          rounded
        ></v-text-field>
        <v-textarea
          v-model="record.options_discord.message"
          :rules="formOptionsDiscordMessageRules"
          density="compact"
          label="Message"
          variant="plain"
          rounded
        ></v-textarea>
      </div>
      <div v-if="record.type === 'webhook'">
        <div>Webhook options:</div>
        <div class="mb-4">
          <InfoMonitor />
        </div>
        <v-text-field
          v-model="record.options_webhook.url"
          :rules="formOptionsDiscordURLRules"
          density="compact"
          label="URL"
          variant="plain"
          rounded
        ></v-text-field>
        <v-select
          v-model="record.options_webhook.method"
          :rules="formOptionsWebhookMethod"
          label="Method"
          :items="allowedWebhookMethods"
        ></v-select>
        <v-textarea
          v-model="record.options_webhook.body"
          density="compact"
          label="Body"
          variant="plain"
          rounded
        ></v-textarea>
        <v-textarea
          v-model="record.options_webhook.headers"
          density="compact"
          label="Headers (Format: Key: Value)"
          variant="plain"
          rounded
        ></v-textarea>
      </div>
    </v-container>
  </v-form>
</template>
