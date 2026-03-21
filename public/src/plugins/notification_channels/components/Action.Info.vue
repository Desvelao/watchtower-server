<script setup>
import ActivatorFlyout from '../../../components/common/Activator.Flyout.vue';

defineProps({
  channel: {
    type: Object,
    required: true,
  },
});
</script>
<template>
  <ActivatorFlyout>
    <template v-slot:activator="{ toggle }">
      <span :onClick="toggle" style="cursor: pointer">{{ channel.name }}</span>
    </template>
    <template v-slot:title
      ><span class="text-h5"
        >Notification channel details: {{ channel.name }}
      </span></template
    >
    <template v-slot:body>
      <div>Name: {{ channel.name }}</div>
      <div>Type: {{ channel.type }}</div>

      <div>Created at: {{ channel.created_at }}</div>
      <div>Updated at: {{ channel.updated_at }}</div>
      <div v-if="channel.type === 'discord'">
        <div>
          URL:
          <a
            :href="channel.options.url"
            target="_blank"
            rel="noopener noreferrer"
            >link</a
          >
        </div>
        <div>Message: {{ channel.options.message }}</div>
      </div>
    </template>
  </ActivatorFlyout>
</template>
