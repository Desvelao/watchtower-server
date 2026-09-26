<template>
  <div class="rounded border border-slate-200 bg-slate-50 p-2 text-xs text-slate-600 dark:border-slate-600 dark:bg-slate-900 dark:text-slate-400">
    <p>
      Use <code class="rounded bg-slate-200 px-1 py-0.5 text-slate-800 dark:bg-slate-700 dark:text-slate-200">{{ MUSTACHE_EXAMPLE }}</code>
      to interpolate fields. One message is sent per matched alert, so each field below refers to that single alert:
    </p>
    <dl class="mt-1.5 space-y-1">
      <div v-for="field in FIELDS" :key="field.name">
        <dt>
          <code class="rounded bg-slate-200 px-1 py-0.5 text-slate-800 dark:bg-slate-700 dark:text-slate-200">{{ wrapToken(field.name) }}</code>
        </dt>
        <dd class="text-slate-500 dark:text-slate-400">{{ field.meaning }}</dd>
      </div>
    </dl>
  </div>
</template>

<script setup>
// Vue's template compiler ends a mustache tag at the first "}}" it sees, so
// a literal "{{ ... }}" can't appear directly inside a {{ }} interpolation's
// source text (it closes early on the inner "}}", leaving a dangling
// fragment and failing to parse). Building these strings here in script,
// and interpolating a plain identifier/call in the template, sidesteps that
// entirely - only their computed runtime values contain braces.
const MUSTACHE_EXAMPLE = '{{ }}';
const wrapToken = (name) => `{{ ${name} }}`;

const FIELDS = [
  { name: 'alert.id', meaning: "The alert's id." },
  { name: 'alert.observable_name', meaning: 'The name of the observable the alert was raised for.' },
  { name: 'alert.severity', meaning: "The alert's severity (low, medium, high, critical)." },
  { name: 'alert.tags', meaning: "The matching rule's tags, comma-separated (empty if none)." },
  { name: 'alert.rule_name', meaning: 'The name of the rule that raised the alert.' },
  { name: 'alert.created_at', meaning: 'When the alert was created.' },
  { name: 'alert.payload.<field>', meaning: "The observed observable's properties for this alert (fields vary per observable type, e.g. alert.payload.price)." },
  { name: 'timestamp', meaning: 'The time this message is sent.' },
];
</script>
