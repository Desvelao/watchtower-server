<script setup>
import { ref } from 'vue';
import { validate } from '../../../services/form';
import * as ScraperAPI from '../api';
import { useAsyncAction } from '../../../hooks/useAction';
import ActionTestForm from './Action.Test.Form.vue';
import ActivatorFlyout from '../../../components/common/Activator.Flyout.vue';
import FormMultipleText from './Form.MultipleText.vue';

const record = defineModel();
const validForm = defineModel('validation');

const formTestURLRules = [validate.isRequired('Test URL')];

const formNameRules = [
  validate.isRequired('Name'),
  validate.stringHasMaxChars(20, 'Name'),
];

const formURLMatcherRules = [validate.isRequired('URL Regex')];

const formSelectorSelector = [validate.isRequired('Selector')];

const formSelectorScript = [validate.isRequired('Script')];

const action = useAsyncAction(async event => {
  try {
    event.preventDefault();
    const { id, name, urls_match, fields, test_url, urls_test } = record.value;

    const response = id
      ? await ScraperAPI.testSite(id, { test_url })
      : await ScraperAPI.testUnregistered({
          name,
          urls_match,
          fields,
          test_url,
          urls_test,
        });

    return response.body.data;
  } catch (error) {}
});
</script>

<template>
  <v-form v-model="validForm" validate-on="input">
    <v-container>
      <v-row>
        <v-col>
          <div class="d-flex justify-between">
            <div class="w-100">
              <v-text-field
                v-model="record.name"
                :rules="formNameRules"
                density="compact"
                label="Name"
                variant="plain"
                rounded
              ></v-text-field>
            </div>
          </div>
        </v-col>
      </v-row>
      <v-divider :thickness="2"></v-divider>
      <v-row>
        <v-col cols="12">
          <div>
            <!-- <div class="w-100">URL matchers:</div> -->
            <div>
              <FormMultipleText
                v-model="record.urls_match"
                label="URL matcher"
                :validate="formURLMatcherRules"
              >
                <template v-slot:body>
                  <div class="text-h7">Define the matchers for the URLs</div>
                </template>
              </FormMultipleText>
            </div>
          </div>
        </v-col>
      </v-row>
      <v-divider :thickness="2"></v-divider>

      <div>Attributes:</div>

      <v-row v-for="(selector, key) in record.fields">
        <v-col cols="12" md="2">
          <div>{{ key }}</div>
        </v-col>
        <v-col cols="12" md="10">
          <v-row>
            <v-col>
              <FormMultipleText
                v-model="record.fields[key].selector"
                label="Selector"
                :validate="formSelectorSelector"
              >
                <template v-slot:body>
                  <div class="text-h7">
                    Define the attribute selectors. Use CSS selectors to select
                    the HTML element. You can use the browser dev tools to get
                    the CSS selector for the element.
                  </div>
                </template>
              </FormMultipleText>
              <v-row>
                <v-col cols="11">
                  <v-text-field
                    v-model="selector.transform"
                    density="compact"
                    label="Transform"
                    variant="plain"
                    rounded
                  ></v-text-field>
                </v-col>
                <v-col cols="1">
                  <div>
                    <ActivatorFlyout>
                      <template v-slot:activator="{ toggle }">
                        <v-icon-btn
                          type="button"
                          icon="mdi-help-circle-outline"
                          size="24"
                          color="primary"
                          title="Help"
                          @click="toggle"
                        >
                          <v-icon size="24"></v-icon>
                        </v-icon-btn>
                      </template>
                      <template v-slot:title>
                        <span class="text-h5">Info</span>
                      </template>
                      <template v-slot:body>
                        <div>Transform the selected element.</div>
                        <div>TODO: Define the built-in transform methods</div>
                      </template>
                    </ActivatorFlyout>
                  </div>
                </v-col>
              </v-row>
              <v-row>
                <v-col cols="11">
                  <v-text-field
                    v-model="selector.validate"
                    density="compact"
                    label="Validate"
                    variant="plain"
                    rounded
                  ></v-text-field>
                </v-col>
                <v-col cols="1">
                  <div>
                    <ActivatorFlyout>
                      <template v-slot:activator="{ toggle }">
                        <v-icon-btn
                          type="button"
                          icon="mdi-help-circle-outline"
                          size="24"
                          color="primary"
                          title="Help"
                          @click="toggle"
                        >
                          <v-icon size="24"></v-icon>
                        </v-icon-btn>
                      </template>
                      <template v-slot:title>
                        <span class="text-h5">Info</span>
                      </template>
                      <template v-slot:body>
                        <div>Validate the attribute value.</div>
                        <div>TODO: Define the built-in validate methods</div>
                      </template>
                    </ActivatorFlyout>
                  </div>
                </v-col>
              </v-row>
            </v-col>
          </v-row>
        </v-col>
      </v-row>

      <v-divider :thickness="2"></v-divider>
      <ActionTestForm
        :validation="validForm"
        :action="action"
        :record="record"
      ></ActionTestForm>
      <v-divider :thickness="2"></v-divider>
      <FormMultipleText v-model="record.urls_test" label="URL testers">
        <template v-slot:body>
          <div class="text-h7">
            Define the URL testers, these help to decide if the scraper
            configuration is ok
          </div>
        </template>
      </FormMultipleText>
    </v-container>
  </v-form>
</template>
