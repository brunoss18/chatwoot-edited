<script setup>
import { computed } from 'vue';

const props = defineProps({
  label: {
    type: String,
    required: true,
  },
  // `risco` é exclusivo do Protocolo Vermelho: nada mais no quadro usa ruby.
  tone: {
    type: String,
    default: 'neutro',
    validator: value => ['risco', 'atencao', 'ok', 'neutro'].includes(value),
  },
});

const TONE_CLASSES = {
  risco: 'bg-n-ruby-3 text-n-ruby-11 border-n-ruby-5',
  atencao: 'bg-n-amber-3 text-n-amber-11 border-n-amber-5',
  ok: 'bg-n-teal-3 text-n-teal-11 border-n-teal-5',
  neutro: 'bg-n-slate-1 text-n-slate-11 border-n-slate-4',
};

const toneClass = computed(() => TONE_CLASSES[props.tone]);
</script>

<template>
  <span
    class="inline-flex items-center gap-1 px-2 py-0.5 border rounded-md text-label-small whitespace-nowrap"
    :class="toneClass"
  >
    <slot name="icon" />
    {{ label }}
  </span>
</template>
