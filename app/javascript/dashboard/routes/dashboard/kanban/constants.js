/**
 * Kanban Clínico Rede Focoh — constantes do quadro.
 *
 * As 6 fases e sua ordem espelham o enum `fase_jornada` do Supabase. Se uma
 * mudar, as duas mudam juntas: o board só desenha o que o banco reconhece.
 */

// Paleta: `n-ruby-*` fica reservado ao flag do Protocolo Vermelho, para que
// vermelho no quadro signifique risco e nada mais. A Fase 3 (laranja na
// documentação) usa amber-11, um degrau mais escuro que o amarelo da Fase 2.
export const FASES_JORNADA = [
  { id: 'admissao_triagem', labelKey: 'ADMISSAO_TRIAGEM', dotClass: 'bg-n-teal-9' },
  { id: 'fase1_autocritica', labelKey: 'FASE_1', dotClass: 'bg-n-blue-9' },
  { id: 'fase2_disciplina', labelKey: 'FASE_2', dotClass: 'bg-n-amber-9' },
  { id: 'fase3_empatia', labelKey: 'FASE_3', dotClass: 'bg-n-amber-11' },
  { id: 'fase4_identidade', labelKey: 'FASE_4', dotClass: 'bg-n-violet-9' },
  { id: 'alta_transicao', labelKey: 'ALTA_TRANSICAO', dotClass: 'bg-n-slate-9' },
];

/**
 * SQLSTATEs levantados pelas travas clínicas no Postgres.
 *
 * O painel exibe a mensagem que vem do banco (fonte única da copy oficial) e
 * usa o código apenas para decidir o formato — modal para bloqueio de fase,
 * toast para o resto.
 */
export const CODIGOS_TRAVA = {
  AVANCO_BLOQUEADO: 'FCH01',
  ARQUIVAMENTO_BLOQUEADO: 'FCH02',
  VISITA_BLOQUEADA: 'FCH03',
  PACIENTE_ARQUIVADO: 'FCH04',
  REGRESSAO_SEM_PAPEL_CLINICO: 'FCH05',
  JORNADA_SEQUENCIAL: 'FCH06',
  ADMISSAO_FORA_DA_COLUNA_1: 'FCH07',
};

export const GRUPO_DRAG = 'focoh-kanban';
