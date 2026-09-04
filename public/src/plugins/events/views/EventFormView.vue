<script setup>
import { onMounted, reactive, ref } from "vue";
import { useRouter } from "vue-router";
import { useEventsStore } from "../../../stores/events";
import { listEvents } from "../../../services/api/events";
import { HTTPError } from "../../../services/api/http";

const router = useRouter();
const store = useEventsStore();

const form = reactive({
  payload: "",
  source: "",
  tags: "",
});

const saving = ref(false);
const error = ref("");

// Recently-used values, offered as quick-fill badges under their fields. No
// dedicated "distinct values" endpoint exists for event fields, so this
// samples the most recent events client-side instead.
const RECENT_SUGGESTIONS_SAMPLE_SIZE = 20;
const RECENT_SUGGESTIONS_LIMIT = 5;
const recentPayloads = ref([]);
const recentSources = ref([]);
const recentTags = ref([]);

function distinctRecentValues(items, extractValues, limit) {
  const seen = new Set();
  const result = [];
  for (const item of items) {
    for (const value of extractValues(item)) {
      if (!value || seen.has(value)) continue;
      seen.add(value);
      result.push(value);
      if (result.length >= limit) return result;
    }
  }
  return result;
}

onMounted(async () => {
  try {
    const { items } = await listEvents({
      sort: "created_at:desc",
      size: RECENT_SUGGESTIONS_SAMPLE_SIZE,
    });
    recentPayloads.value = distinctRecentValues(
      items || [],
      (item) => [item.payload],
      RECENT_SUGGESTIONS_LIMIT
    );
    recentSources.value = distinctRecentValues(
      items || [],
      (item) => [item.source],
      RECENT_SUGGESTIONS_LIMIT
    );
    recentTags.value = distinctRecentValues(
      items || [],
      (item) => item.tags || [],
      RECENT_SUGGESTIONS_LIMIT
    );
  } catch (err) {
    // Quick-fill badges are a convenience, not required for the form to
    // work - fail silently rather than surfacing a form-level error.
  }
});

function toRequestBody() {
  const tags = form.tags
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);

  const body = {
    payload: form.payload,
    source: form.source,
  };

  // The backend inserts tags as a Postgres array literal (ARRAY[...]) and
  // fails with "cannot determine type of empty array" if sent as `[]` -
  // omit the key entirely when there are no tags.
  if (tags.length > 0) {
    body.tags = tags;
  }

  return body;
}

async function onSubmit() {
  error.value = "";
  saving.value = true;
  try {
    await store.create(toRequestBody());
    router.push('/events');
  } catch (err) {
    if (err instanceof HTTPError) {
      const body = err.response.body;
      error.value = body?.errors?.join(", ") || body?.message || body?.error || "Save failed";
    } else {
      error.value = "Save failed";
    }
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <div class="max-w-xl">
    <h1 class="text-xl font-semibold text-slate-900 dark:text-slate-100">New event</h1>

    <form class="mt-4 space-y-4 rounded-lg border border-slate-200 bg-white p-5 dark:border-slate-700 dark:bg-slate-800" @submit.prevent="onSubmit">
      <div>
        <label for="event-payload" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Payload</label>
        <input
          id="event-payload"
          v-model="form.payload"
          type="text"
          placeholder="Optional description, e.g. 'Living room smoke detector'"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
          Describes what happened. Creating this event resolves a dispatch action automatically by
          matching its properties against the configured <RouterLink to="/rules" class="underline">rules</RouterLink>,
          and creates the resulting alert.
        </p>
        <div v-if="recentPayloads.length" class="mt-2 flex flex-wrap items-center gap-1.5">
          <span class="text-xs text-slate-500 dark:text-slate-400">Recently used:</span>
          <button
            v-for="payload in recentPayloads"
            :key="payload"
            type="button"
            :title="payload"
            class="max-w-[220px] truncate rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
            @click="form.payload = payload"
          >
            {{ payload }}
          </button>
        </div>
      </div>
      <div>
        <label for="event-source" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Source</label>
        <input id="event-source" v-model="form.source" type="text" class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100" />
        <div v-if="recentSources.length" class="mt-2 flex flex-wrap items-center gap-1.5">
          <span class="text-xs text-slate-500 dark:text-slate-400">Recently used:</span>
          <button
            v-for="source in recentSources"
            :key="source"
            type="button"
            :title="source"
            class="max-w-[220px] truncate rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
            @click="form.source = source"
          >
            {{ source }}
          </button>
        </div>
      </div>
      <div>
        <label for="event-tags" class="block text-sm font-medium text-slate-700 dark:text-slate-300">Tags</label>
        <input
          id="event-tags"
          v-model="form.tags"
          type="text"
          placeholder="comma, separated, tags"
          class="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm dark:border-slate-600 dark:bg-slate-900 dark:text-slate-100"
        />
        <div v-if="recentTags.length" class="mt-2 flex flex-wrap items-center gap-1.5">
          <span class="text-xs text-slate-500 dark:text-slate-400">Recently used:</span>
          <button
            v-for="tag in recentTags"
            :key="tag"
            type="button"
            :title="tag"
            class="max-w-[220px] truncate rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-600 hover:bg-slate-200 dark:bg-slate-700 dark:text-slate-300 dark:hover:bg-slate-600"
            @click="form.tags = tag"
          >
            {{ tag }}
          </button>
        </div>
      </div>
      <p v-if="error" class="text-sm text-red-600 dark:text-red-400">{{ error }}</p>

      <div class="flex justify-end gap-2">
        <RouterLink
          to="/events"
          class="rounded px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
        >
          Cancel
        </RouterLink>
        <button
          type="submit"
          :disabled="saving"
          class="rounded bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50 dark:bg-slate-700 dark:hover:bg-slate-600"
        >
          {{ saving ? "Saving..." : "Save" }}
        </button>
      </div>
    </form>
  </div>
</template>
