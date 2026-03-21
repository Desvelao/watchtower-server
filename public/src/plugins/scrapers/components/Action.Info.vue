<script setup>
import ActivatorFlyout from '../../../components/common/Activator.Flyout.vue';

const props = defineProps({
  data: {
    type: Object,
    required: true,
  },
});
</script>

<template>
  <ActivatorFlyout>
    <template v-slot:activator="{ toggle }">
      <span :onClick="toggle" style="cursor: pointer">{{ data.name }}</span>
    </template>
    <template v-slot:title
      ><span class="text-h5"
        >Site scraper details: {{ data.name }}
      </span></template
    >
    <template v-slot:body>
      <div>Name: {{ data.name }}</div>
      <div>Match: {{ data.urls_match }}</div>

      <div>Created at: {{ data.created_at }}</div>
      <div>Updated at: {{ data.updated_at }}</div>
      <div>
        <div>Scrap</div>
        <div v-for="({ selector, transform, validate }, prop) in data.fields">
          <div>
            <div>{{ prop }}</div>
            <div>
              selector: <code class="scp_remote_lua">{{ selector }}</code>
            </div>
            <div>
              transform: <code class="scp_remote_lua">{{ transform }}</code>
            </div>
            <div>
              validate: <code class="scp_remote_lua">{{ transform }}</code>
            </div>
          </div>
        </div>
      </div>
    </template>
  </ActivatorFlyout>
</template>
