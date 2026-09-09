<script setup>
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';
import KanbanCard from './KanbanCard.vue';
import { GRUPO_DRAG } from '../constants';

/**
 * Uma das 6 colunas da jornada.
 *
 * `cards` é mutado pelo vuedraggable no drop (movimento otimista). Quem decide
 * se o movimento vale é o banco: a página escuta `move` e, se a trava rejeitar,
 * recarrega o quadro — o que devolve o cartão à coluna de origem sem que este
 * componente precise saber de rollback.
 */
defineProps({
  fase: {
    type: Object,
    required: true,
  },
  cards: {
    type: Array,
    required: true,
  },
  isDragDisabled: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['move']);

const { t } = useI18n();

const onChange = event => {
  if (!event.added) return;
  emit('move', event.added.element);
};
</script>

<template>
  <section class="flex flex-col min-w-0 gap-3">
    <header class="flex flex-col gap-1 px-1">
      <div class="flex items-center gap-2 min-w-0">
        <span class="rounded-full size-2 shrink-0" :class="fase.dotClass" />
        <h2 class="truncate text-heading-3 text-n-slate-12">
          {{ t(`KANBAN.FASES.${fase.labelKey}.NOME`) }}
        </h2>
        <span class="text-label-small text-n-slate-11 shrink-0">
          {{ cards.length }}
        </span>
      </div>
      <p class="truncate text-label-small text-n-slate-10">
        {{ t(`KANBAN.FASES.${fase.labelKey}.TEMPO`) }}
      </p>
    </header>

    <Draggable
      :list="cards"
      :group="GRUPO_DRAG"
      :disabled="isDragDisabled"
      item-key="id"
      tag="ul"
      role="list"
      class="flex flex-col flex-1 gap-2 p-2 rounded-xl bg-n-alpha-2 min-h-24"
      @change="onChange"
    >
      <template #item="{ element }">
        <li class="list-none">
          <KanbanCard :card="element" :is-draggable="!isDragDisabled" />
        </li>
      </template>
      <template #footer>
        <p
          v-if="!cards.length"
          class="px-1 py-2 text-label-small text-n-slate-10"
        >
          {{ t('KANBAN.COLUNA_VAZIA') }}
        </p>
      </template>
    </Draggable>
  </section>
</template>
