<script setup>
import { ref, watch, onMounted, useTemplateRef } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import KanbanCard from '../components/KanbanCard.vue';
import KanbanColumn from '../components/KanbanColumn.vue';
import { useFocohKanban } from '../useFocohKanban';
import { FASES_JORNADA, CODIGOS_TRAVA } from '../constants';

const { t } = useI18n();

const {
  isConfigured,
  temSessao,
  cards,
  cardsPorFase,
  isLoading,
  erroCarregamento,
  carregarCards,
  moverPaciente,
} = useFocohKanban();

const dialogBloqueio = useTemplateRef('dialogBloqueio');
const mensagemBloqueio = ref('');

// O vuedraggable move itens entre arrays, então cada coluna precisa do seu
// próprio array mutável. `cardsPorFase` é a leitura derivada do banco; `quadro`
// é a cópia que o arraste manipula até o banco confirmar ou negar.
const quadro = ref({});

const sincronizarQuadro = () => {
  quadro.value = Object.fromEntries(
    FASES_JORNADA.map(fase => [fase.id, [...(cardsPorFase.value[fase.id] ?? [])]])
  );
};

watch(cards, sincronizarQuadro, { immediate: true });

const onMove = async (card, faseDestino) => {
  const { ok, error } = await moverPaciente(card.id, faseDestino);

  if (!ok) {
    // A copy oficial de bloqueio mora no banco; o i18n é só rede de proteção
    // para o caso de a mensagem não chegar.
    const mensagem = error?.message || t('KANBAN.BLOQUEIO.FALLBACK');

    if (error?.code === CODIGOS_TRAVA.AVANCO_BLOQUEADO) {
      mensagemBloqueio.value = mensagem;
      dialogBloqueio.value.open();
    } else {
      useAlert(mensagem);
    }
  }

  // Recarregar em qualquer desfecho: se foi negado, devolve o cartão à coluna
  // de origem; se foi aceito, atualiza os flags derivados (laudos da semana,
  // pode_avancar) que a nova fase muda.
  await carregarCards();
};

onMounted(carregarCards);
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header class="px-6 pt-6 shrink-0">
      <h1 class="text-heading-1 text-n-slate-12">
        {{ t('KANBAN.HEADER') }}
      </h1>
      <p class="mt-1 text-body-main text-n-slate-11">
        {{ t('KANBAN.SUBTITULO') }}
      </p>
    </header>

    <div
      v-if="!isConfigured"
      class="flex items-center justify-center flex-1 px-6"
    >
      <p class="max-w-md text-center text-body-main text-n-slate-11">
        {{ t('KANBAN.ESTADO.SEM_CONFIGURACAO') }}
      </p>
    </div>

    <div
      v-else-if="isLoading && !cards.length"
      class="flex items-center justify-center flex-1"
    >
      <Spinner :size="24" />
    </div>

    <div
      v-else-if="erroCarregamento"
      class="flex items-center justify-center flex-1 px-6"
    >
      <p class="max-w-md text-center text-body-main text-n-ruby-11">
        {{ erroCarregamento.message }}
      </p>
    </div>

    <div
      v-else-if="!temSessao"
      class="flex items-center justify-center flex-1 px-6"
    >
      <p class="max-w-md text-center text-body-main text-n-slate-11">
        {{ t('KANBAN.ESTADO.SEM_SESSAO') }}
      </p>
    </div>

    <template v-else>
      <!--
        Requisito oficial: o formato de colunas é desktop-only. Em celular
        corporativo o padrão é lista, sem arraste — progressão de fase não é
        gesto de tela pequena.
      -->
      <main class="flex-1 hidden px-6 py-4 overflow-x-auto md:block">
        <div class="grid grid-flow-col auto-cols-[minmax(17rem,1fr)] gap-4 h-full">
          <KanbanColumn
            v-for="fase in FASES_JORNADA"
            :key="fase.id"
            :fase="fase"
            :cards="quadro[fase.id] ?? []"
            @move="card => onMove(card, fase.id)"
          />
        </div>
      </main>

      <main class="flex-1 px-4 py-4 overflow-y-auto md:hidden">
        <div
          v-for="fase in FASES_JORNADA"
          :key="fase.id"
          class="flex flex-col gap-2 mb-6"
        >
          <div class="flex items-center gap-2">
            <span class="rounded-full size-2 shrink-0" :class="fase.dotClass" />
            <h2 class="text-heading-3 text-n-slate-12">
              {{ t(`KANBAN.FASES.${fase.labelKey}.NOME`) }}
            </h2>
            <span class="text-label-small text-n-slate-11">
              {{ (quadro[fase.id] ?? []).length }}
            </span>
          </div>
          <p
            v-if="!(quadro[fase.id] ?? []).length"
            class="text-label-small text-n-slate-10"
          >
            {{ t('KANBAN.COLUNA_VAZIA') }}
          </p>
          <KanbanCard
            v-for="card in quadro[fase.id] ?? []"
            :key="card.id"
            :card="card"
          />
        </div>
      </main>
    </template>

    <Dialog
      ref="dialogBloqueio"
      type="alert"
      width="md"
      :title="t('KANBAN.BLOQUEIO.TITULO')"
      :description="mensagemBloqueio"
      :show-cancel-button="false"
      :confirm-button-label="t('KANBAN.BLOQUEIO.ENTENDI')"
      @confirm="dialogBloqueio.close()"
    />
  </section>
</template>
