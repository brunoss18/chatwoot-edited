<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import KanbanCardFlag from './KanbanCardFlag.vue';

/**
 * Cartão do paciente.
 *
 * O objeto `card` vem de `cards_do_quadro()` e não contém escore de risco,
 * nível textual nem detalhes de ideação — este componente não tem como
 * vazá-los porque não os recebe. O risco aparece só como estado:
 * "Protocolo Vermelho ativo" ou "pendência clínica".
 */
const props = defineProps({
  card: {
    type: Object,
    required: true,
  },
  isDraggable: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();

const laudosPendentes = computed(() => props.card.laudos_pendentes?.length ?? 0);

const avaliacaoDeRiscoPendente = computed(
  () => props.card.nivel_pendencia === 'sem_avaliacao_risco'
);
</script>

<template>
  <article
    class="flex flex-col w-full gap-2 p-3 border rounded-xl bg-n-solid-2 border-n-weak"
    :class="isDraggable ? 'cursor-grab active:cursor-grabbing' : ''"
  >
    <div class="flex flex-col gap-0.5 min-w-0">
      <h3 class="truncate text-heading-3 text-n-slate-12">
        {{ card.nome }}
      </h3>
      <p class="truncate text-label-small text-n-slate-11">
        <span v-if="card.programa">{{ card.programa }} · </span>
        {{ t('KANBAN.CARD.DIAS_INTERNADO', card.dias_internado) }}
      </p>
    </div>

    <div class="flex flex-wrap gap-1">
      <KanbanCardFlag
        v-if="card.protocolo_vermelho_ativo"
        tone="risco"
        :label="t('KANBAN.CARD.PROTOCOLO_VERMELHO')"
      >
        <template #icon>
          <span class="rounded-full size-1.5 bg-n-ruby-9 shrink-0" />
        </template>
      </KanbanCardFlag>

      <KanbanCardFlag
        v-if="avaliacaoDeRiscoPendente"
        tone="atencao"
        :label="t('KANBAN.CARD.SEM_AVALIACAO_RISCO')"
      />

      <KanbanCardFlag
        v-if="card.tem_3_laudos"
        tone="ok"
        :label="t('KANBAN.CARD.LAUDOS_APROVADOS')"
      />
      <KanbanCardFlag
        v-else
        tone="atencao"
        :label="t('KANBAN.CARD.LAUDOS_PENDENTES', laudosPendentes)"
      />

      <KanbanCardFlag
        v-if="card.pode_avancar"
        tone="ok"
        :label="t('KANBAN.CARD.APTO_A_AVANCAR')"
      />
    </div>
  </article>
</template>
