<script setup>
import { computed, ref } from "vue";
import { formatDate } from "../../utils/date";

// `buckets`: chronological, evenly-spaced, zero-filled array of
// { time: Date, count: number } - one entry per bucket in the selected
// range, including empty ones (the caller fills the gaps so bars stay
// evenly spaced/correctly positioned in time rather than only reflecting
// whichever buckets happened to have data).
const props = defineProps({
  buckets: { type: Array, required: true },
  bucketUnit: { type: String, required: true }, // 'minute' | 'hour' | 'day'
  // SVG viewBox height in user units (width is fixed at 800) - lower this
  // for a more compact chart; rendered pixel height scales with it since
  // the chart is `w-full` with no CSS height override.
  height: { type: Number, default: 110 },
  ariaLabel: { type: String, default: "Value over time" },
  // Used to build the per-bar and tooltip labels, e.g. "42 heartbeats".
  unitLabel: { type: String, default: "items" },
  // 'count': bar height proportional to `count` (the default, magnitude
  // chart with a numeric y-axis). 'connectivity': every bar is full height,
  // colored by whether `count > 0` (presence/absence, no numeric scale).
  variant: { type: String, default: "count" },
});

const isConnectivity = computed(() => props.variant === "connectivity");

const CHART_WIDTH = 800;
const PADDING = { top: 12, right: 8, bottom: 24, left: 32 };
const plotWidth = CHART_WIDTH - PADDING.left - PADDING.right;
const plotHeight = computed(() => props.height - PADDING.top - PADDING.bottom);
const BAR_RADIUS = 3;
const MAX_BAR_WIDTH = 24;

const hoveredIndex = ref(null);

const maxCount = computed(() => Math.max(1, ...props.buckets.map((b) => b.count)));

const gridlineValues = computed(() => {
  const max = maxCount.value;
  const mid = Math.round(max / 2);
  return mid > 0 && mid < max ? [0, mid, max] : [0, max];
});

function yForValue(value) {
  return PADDING.top + plotHeight.value - (value / maxCount.value) * plotHeight.value;
}

const bandWidth = computed(() =>
  props.buckets.length > 0 ? plotWidth / props.buckets.length : plotWidth
);

const bars = computed(() =>
  props.buckets.map((b, i) => {
    const barWidth = Math.min(MAX_BAR_WIDTH, bandWidth.value - 2);
    const bandX = PADDING.left + i * bandWidth.value;
    const x = bandX + (bandWidth.value - barWidth) / 2;
    const height = isConnectivity.value
      ? plotHeight.value
      : (b.count / maxCount.value) * plotHeight.value;
    const y = PADDING.top + plotHeight.value - height;
    return { ...b, index: i, x, y, width: Math.max(0, barWidth), height, bandX, connected: b.count > 0 };
  })
);

function barFillClass(bar) {
  if (isConnectivity.value) {
    if (bar.connected) {
      return hoveredIndex.value === bar.index
        ? "fill-green-600 dark:fill-green-500"
        : "fill-green-500 dark:fill-green-600";
    }
    return hoveredIndex.value === bar.index
      ? "fill-slate-400 dark:fill-slate-500"
      : "fill-slate-300 dark:fill-slate-600";
  }
  return hoveredIndex.value === bar.index
    ? "fill-slate-700 dark:fill-slate-300"
    : "fill-slate-500 dark:fill-slate-400";
}

function barAriaLabel(bar) {
  if (isConnectivity.value) {
    return `${formatAxisLabel(bar.time)}: ${bar.connected ? "Connected" : "No heartbeat"}`;
  }
  return `${formatAxisLabel(bar.time)}: ${bar.count} ${props.unitLabel}`;
}

function barPath(bar) {
  const { x, y, width, height } = bar;
  if (height <= 0 || width <= 0) return "";
  const r = Math.min(BAR_RADIUS, width / 2, height);
  if (r <= 0) {
    return `M${x},${y + height} L${x},${y} L${x + width},${y} L${x + width},${y + height} Z`;
  }
  return [
    `M${x},${y + height}`,
    `L${x},${y + r}`,
    `Q${x},${y} ${x + r},${y}`,
    `L${x + width - r},${y}`,
    `Q${x + width},${y} ${x + width},${y + r}`,
    `L${x + width},${y + height}`,
    "Z",
  ].join(" ");
}

// Show at most ~6 x-axis labels, evenly spaced, so 60/168-bucket ranges
// don't collide into an unreadable smear of text.
const labelIndices = computed(() => {
  const n = props.buckets.length;
  if (n === 0) return [];
  const step = Math.max(1, Math.ceil(n / 6));
  const indices = [];
  for (let i = 0; i < n; i += step) indices.push(i);
  if (indices[indices.length - 1] !== n - 1) indices.push(n - 1);
  return indices;
});

// The first/last ticks sit at the plot's edges - centering their text
// would overflow past the SVG viewBox and get clipped, so they anchor
// toward the inside instead.
function labelAnchor(i) {
  if (i === 0) return "start";
  if (i === props.buckets.length - 1) return "end";
  return "middle";
}

function labelX(bar, i) {
  if (i === 0) return bar.bandX;
  if (i === props.buckets.length - 1) return bar.bandX + bandWidth.value;
  return bar.bandX + bandWidth.value / 2;
}

function formatAxisLabel(date) {
  if (props.bucketUnit === "minute") {
    return date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });
  }
  if (props.bucketUnit === "hour") {
    return date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", hour12: false });
  }
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

const hovered = computed(() =>
  hoveredIndex.value !== null ? bars.value[hoveredIndex.value] : null
);
</script>

<template>
  <div class="relative">
    <svg
      :viewBox="`0 0 ${CHART_WIDTH} ${height}`"
      class="w-full"
      role="img"
      :aria-label="ariaLabel"
    >
      <!-- gridlines: a numeric scale doesn't apply to a connectivity
           (presence/absence) view -->
      <template v-if="!isConnectivity">
        <g v-for="v in gridlineValues" :key="v">
          <line
            :x1="PADDING.left"
            :x2="CHART_WIDTH - PADDING.right"
            :y1="yForValue(v)"
            :y2="yForValue(v)"
            class="stroke-slate-200 dark:stroke-slate-700"
            stroke-width="1"
          />
          <text
            :x="PADDING.left - 6"
            :y="yForValue(v)"
            dy="0.32em"
            text-anchor="end"
            class="fill-slate-400 dark:fill-slate-500"
            font-size="8"
          >
            {{ v }}
          </text>
        </g>
      </template>

      <!-- bars -->
      <g v-for="bar in bars" :key="bar.index">
        <path :d="barPath(bar)" class="transition-colors" :class="barFillClass(bar)" />
        <!-- oversized, invisible hit target spanning the full band/height,
             per dataviz guidance that the hit area must exceed the painted
             mark -->
        <rect
          :x="bar.bandX"
          :y="PADDING.top"
          :width="bandWidth"
          :height="plotHeight"
          fill="transparent"
          tabindex="0"
          role="img"
          :aria-label="barAriaLabel(bar)"
          @pointerenter="hoveredIndex = bar.index"
          @pointerleave="hoveredIndex = null"
          @focus="hoveredIndex = bar.index"
          @blur="hoveredIndex = null"
        />
      </g>

      <!-- x-axis labels -->
      <text
        v-for="i in labelIndices"
        :key="i"
        :x="labelX(bars[i], i)"
        :y="height - 6"
        :text-anchor="labelAnchor(i)"
        class="fill-slate-400 dark:fill-slate-500"
        font-size="8"
      >
        {{ formatAxisLabel(bars[i].time) }}
      </text>
    </svg>

    <div
      v-if="hovered"
      class="pointer-events-none absolute top-1 right-1 rounded border border-slate-200 bg-white px-2 py-1 text-xs shadow-sm dark:border-slate-600 dark:bg-slate-800"
    >
      <template v-if="isConnectivity">
        <span
          class="font-semibold"
          :class="hovered.connected ? 'text-green-700 dark:text-green-400' : 'text-slate-500 dark:text-slate-400'"
        >
          {{ hovered.connected ? "Connected" : "No heartbeat" }}
        </span>
        <span class="text-slate-500 dark:text-slate-400"> · {{ formatDate(hovered.time) }}</span>
      </template>
      <template v-else>
        <span class="font-semibold text-slate-900 dark:text-slate-100">{{ hovered.count }}</span>
        <span class="text-slate-500 dark:text-slate-400"> {{ unitLabel }} · {{ formatDate(hovered.time) }}</span>
      </template>
    </div>
  </div>
</template>
