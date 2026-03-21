<script setup>
import { validate } from '../../services/form';

const record = defineModel();
const validForm = defineModel('validation');

const formNameRules = [
  validate.isRequired('Name'),
  validate.stringHasMaxChars(20, 'Name'),
];

const formURLRules = [validate.isRequired('URL'), validate.isURL];

function copyBookmarklet() {
  const code = `javascript:(function() {fetch('${window.location.origin}/api/items', {method: 'POST', headers: {'Content-Type': 'application/json'}, body:JSON.stringify({enabled: true, name: 'shared'+Date.now(), url: window.location.href})}).then(r => r.json()).then(r => alert(JSON.stringify(r))).catch(e => alert('Error: ' + e.message));})();`;
  if (navigator.clipboard) {
    // Work in https or localhost
    navigator.clipboard.writeText(code).then(() => {
      alert(
        "Bookmarklet code copied! Paste it into a new bookmark's URL field.",
      );
    });
  } else {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    document.body.appendChild(textarea);
    textarea.select();
    document.execCommand('copy');
    document.body.removeChild(textarea);
    alert("Bookmarklet code copied! Paste it into a new bookmark's URL field.");
  }
}

/*
:rules="formNameRules"
javascript:(function() {fetch('http://localhost:8080/api/items', {method: 'POST', headers: {'Content-Type': 'application/json'}, body:JSON.stringify({enabled: true, name: 'test000', url: window.location.href})}).then(r => r.json()).then(r => alert(JSON.stringify(r))).catch(e => alert('Error: ' + e.message));})();
*/
</script>

<template>
  <v-form v-model="validForm">
    <v-container>
      <v-row>
        <v-col>
          <v-text-field
            v-model="record.name"
            density="compact"
            label="Name (optional)"
            variant="plain"
            rounded
          ></v-text-field>
        </v-col>
        <v-col>
          <v-checkbox v-model="record.enabled" label="Enabled"></v-checkbox>
        </v-col>
      </v-row>
      <v-row>
        <v-col>
          <v-text-field
            v-model="record.url"
            :rules="formURLRules"
            density="compact"
            label="URL"
            variant="plain"
            rounded
          ></v-text-field>
        </v-col>
      </v-row>
      <v-row>
        <v-col>
          <div>Tips</div>
          <div>
            <span
              >Create item through bookmaklet. Create a bookmarklet, edit the
              URL and paste:</span
            >
            <v-btn color="primary" @click="copyBookmarklet"
              >Copy bookmarklet</v-btn
            >
          </div>
        </v-col>
      </v-row>
    </v-container>
  </v-form>
</template>
