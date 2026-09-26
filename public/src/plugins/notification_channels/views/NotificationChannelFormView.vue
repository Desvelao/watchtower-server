<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useNotificationChannelsStore } from '../../../stores/notificationChannels';
import { listNotificationChannels } from '../../../services/api/notification_channels';
import { HTTPError } from '../../../services/api/http';
import InfoMonitor from '../../../components/InfoMonitor.vue';

const props = defineProps({
  id: { type: String, default: null },
});

const route = useRoute();
const router = useRouter();
const store = useNotificationChannelsStore();

const channelId = computed(() => props.id || route.params.id || null);
const isEdit = computed(() => !!channelId.value);

const WEBHOOK_METHODS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH'];

const form = reactive({
  name: '',
  type: 'discord',
  discord: { url: '', message: '' },
  webhook: { method: 'POST', url: '', body: '', headers: '' },
  email: { to_addresses: '', subject: '', body: '' },
});

const loading = ref(isEdit.value);
const saving = ref(false);
const error = ref('');

function applyChannel(channel) {
  form.name = channel.name;
  form.type = channel.type;
  if (channel.type === 'discord') {
    form.discord.url = channel.options?.url || '';
    form.discord.message = channel.options?.message || '';
  } else if (channel.type === 'webhook') {
    form.webhook.method = channel.options?.method || 'POST';
    form.webhook.url = channel.options?.url || '';
    form.webhook.body = channel.options?.body || '';
    form.webhook.headers = channel.options?.headers || '';
  } else if (channel.type === 'email') {
    form.email.to_addresses = channel.options?.to_addresses || '';
    form.email.subject = channel.options?.subject || '';
    form.email.body = channel.options?.body || '';
  }
}

onMounted(async () => {
  if (!isEdit.value) return;

  const cached = store.findById(channelId.value);
  if (cached) {
    applyChannel(cached);
    loading.value = false;
    return;
  }

  try {
    const { items } = await listNotificationChannels({ id: channelId.value });
    if (items && items[0]) {
      applyChannel(items[0]);
    } else {
      error.value = 'Notification channel not found.';
    }
  } catch (err) {
    error.value = 'Failed to load notification channel.';
  } finally {
    loading.value = false;
  }
});

async function onSubmit() {
  error.value = '';
  if (!form.name.trim()) {
    error.value = 'Name is required.';
    return;
  }

  let options;
  if (form.type === 'discord') {
    options = { ...form.discord };
    if (!options.url.trim()) {
      error.value = 'URL is required.';
      return;
    }
  } else if (form.type === 'webhook') {
    options = { ...form.webhook };
    if (!options.url.trim()) {
      error.value = 'URL is required.';
      return;
    }
  } else {
    options = { ...form.email };
    if (!options.to_addresses.trim() || !options.subject.trim() || !options.body.trim()) {
      error.value = 'Recipients, subject and body are required.';
      return;
    }
  }

  const payload = { name: form.name, type: form.type, options };

  saving.value = true;
  try {
    if (isEdit.value) {
      await store.update(channelId.value, payload);
    } else {
      await store.create(payload);
    }
    router.push('/notifications_channels');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.message || body?.error || 'Save failed';
    } else {
      error.value = 'Save failed';
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="max-w-2xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">
      {{ isEdit ? `Edit notification channel #${channelId}` : 'New notification channel' }}
    </h1>

    <p v-if="loading" class="mt-4 text-sm text-slate-500 dark:text-slate-400">Loading...</p>

    <form v-else class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="channel-name">Name</label>
        <input
          id="channel-name"
          v-model="form.name"
          type="text"
          maxlength="20"
          required
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="channel-type">Type</label>
        <select
          id="channel-type"
          v-model="form.type"
          class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        >
          <option value="discord">discord</option>
          <option value="webhook">webhook</option>
          <option value="email">email</option>
        </select>
      </div>

      <div v-if="form.type === 'discord'" class="space-y-3 border-t border-slate-200 pt-4 dark:border-slate-700">
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Discord options</h2>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="discord-url">Webhook URL</label>
          <input
            id="discord-url"
            v-model="form.discord.url"
            type="text"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="discord-message">Message</label>
          <textarea
            id="discord-message"
            v-model="form.discord.message"
            rows="3"
            maxlength="255"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          ></textarea>
          <InfoMonitor class="mt-2" />
        </div>
      </div>

      <div v-else-if="form.type === 'webhook'" class="space-y-3 border-t border-slate-200 pt-4 dark:border-slate-700">
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Webhook options</h2>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="webhook-url">URL</label>
          <input
            id="webhook-url"
            v-model="form.webhook.url"
            type="text"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="webhook-method">Method</label>
          <select
            id="webhook-method"
            v-model="form.webhook.method"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          >
            <option v-for="method in WEBHOOK_METHODS" :key="method" :value="method">{{ method }}</option>
          </select>
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="webhook-body">Body</label>
          <textarea
            id="webhook-body"
            v-model="form.webhook.body"
            rows="3"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          ></textarea>
          <InfoMonitor class="mt-2" />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="webhook-headers">Headers (format: Key: Value)</label>
          <textarea
            id="webhook-headers"
            v-model="form.webhook.headers"
            rows="3"
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          ></textarea>
        </div>
      </div>

      <div v-else-if="form.type === 'email'" class="space-y-3 border-t border-slate-200 pt-4 dark:border-slate-700">
        <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Email options</h2>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="email-to">Recipients (comma-separated)</label>
          <input
            id="email-to"
            v-model="form.email.to_addresses"
            type="text"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="email-subject">Subject</label>
          <input
            id="email-subject"
            v-model="form.email.subject"
            type="text"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-slate-700 dark:text-slate-300" for="email-body">Body</label>
          <textarea
            id="email-body"
            v-model="form.email.body"
            rows="3"
            required
            class="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
          ></textarea>
          <InfoMonitor class="mt-2" />
        </div>
      </div>

      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/notifications_channels"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? 'Saving...' : 'Save' }}
        </button>
      </div>
    </form>
  </div>
</template>
