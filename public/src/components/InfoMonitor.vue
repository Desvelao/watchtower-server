<template>
  <div>
    <div class="text-caption">
      Use <span>{}</span> to interpolate fields, this depends on the alerts
      manager.
    </div>
    <div>
      <div class="text-caption">alert-server-connector</div>
      <div class="text-caption">
        <span class="code">ctx</span> is the context of the monitored + scraped
        data
      </div>
      <div class="text-caption">
        <span class="code">alert</span> is the alert information
      </div>
      <div class="text-caption">
        <span class="code">channel</span> is the notification channel context
      </div>
    </div>
  </div>
</template>

<style scoped>
.code {
  padding: 2px;
  background-color: gray;
  color: yellow;
}
</style>
