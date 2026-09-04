<script setup>
import { computed } from "vue";
import { Codemirror } from "vue-codemirror";
import { basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { yaml } from "@codemirror/lang-yaml";
import { json } from "@codemirror/lang-json";
import { useThemeStore } from "../../stores/theme";

const props = defineProps({
  modelValue: { type: String, default: "" },
  language: { type: String, default: "text" },
  minHeight: { type: String, default: "16rem" },
  readOnly: { type: Boolean, default: false },
});

defineEmits(["update:modelValue"]);

const theme = useThemeStore();

// Add an entry here to support another language without changing any
// consumer.
const LANGUAGES = {
  yaml: () => yaml(),
  json: () => json(),
};

// Tailwind's default slate palette, matched by hand so the editor blends
// into the surrounding form instead of bringing in a mismatched theme
// package's own colors.
const SLATE = {
  50: "#f8fafc",
  100: "#f1f5f9",
  300: "#cbd5e1",
  400: "#94a3b8",
  500: "#64748b",
  800: "#1e293b",
  900: "#0f172a",
};

const highlightStyle = HighlightStyle.define([
  { tag: tags.comment, color: SLATE[500], fontStyle: "italic" },
  { tag: tags.propertyName, color: "#0284c7" },
  { tag: [tags.string, tags.special(tags.string)], color: "#16a34a" },
  { tag: [tags.number, tags.bool, tags.null], color: "#d97706" },
  { tag: [tags.punctuation, tags.operator], color: SLATE[400] },
]);

const editorTheme = computed(() =>
  EditorView.theme(
    {
      "&": {
        backgroundColor: theme.isDark ? SLATE[900] : "#ffffff",
        color: theme.isDark ? SLATE[100] : SLATE[900],
        fontSize: "0.875rem",
      },
      ".cm-content": {
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
        minHeight: props.minHeight,
      },
      ".cm-scroller": { minHeight: props.minHeight },
      ".cm-gutters": {
        backgroundColor: theme.isDark ? SLATE[800] : SLATE[50],
        color: theme.isDark ? SLATE[500] : SLATE[400],
        border: "none",
      },
      "&.cm-focused": { outline: "none" },
    },
    { dark: theme.isDark },
  ),
);

const extensions = computed(() => [
  basicSetup,
  (LANGUAGES[props.language] || (() => []))(),
  syntaxHighlighting(highlightStyle),
  editorTheme.value,
  EditorState.readOnly.of(props.readOnly),
  EditorView.editable.of(!props.readOnly),
]);
</script>

<template>
  <div class="mt-1 overflow-hidden rounded border border-slate-300 dark:border-slate-600">
    <Codemirror
      :model-value="modelValue"
      :extensions="extensions"
      :indent-with-tab="true"
      :tab-size="2"
      @update:model-value="$emit('update:modelValue', $event)"
    />
  </div>
</template>
