import { ref, computed } from 'vue';
import { createClient } from '@supabase/supabase-js';

/**
 * Ponte entre o board Vue e o Supabase, que é o sistema-fonte dos dados
 * clínicos. Nada de clínico é replicado no Postgres do Chatwoot.
 *
 * O board lê exclusivamente a função `cards_do_quadro()`: ela devolve flags
 * derivados e nunca o escore de risco. Ler `avaliacoes_risco` daqui não é uma
 * questão de disciplina — a RLS não devolveria linha alguma para recepção.
 */

const SUPABASE_URL = import.meta.env.VITE_FOCOH_SUPABASE_URL;
const SUPABASE_ANON_KEY = import.meta.env.VITE_FOCOH_SUPABASE_ANON_KEY;

// Ausência das variáveis é erro de deploy, não estado de operação: o board
// mostra isso na cara do operador em vez de aparecer vazio, que pareceria
// "nenhum paciente internado".
const isConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

let client = null;

const getClient = () => {
  if (!isConfigured) return null;
  if (!client) {
    client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
  return client;
};

export function useFocohKanban() {
  const cards = ref([]);
  const isLoading = ref(false);
  const erroCarregamento = ref(null);
  const temSessao = ref(false);

  const cardsPorFase = computed(() =>
    cards.value.reduce((acc, card) => {
      acc[card.fase] = acc[card.fase] || [];
      acc[card.fase].push(card);
      return acc;
    }, {})
  );

  const carregarCards = async () => {
    const supabase = getClient();
    if (!supabase) return;

    isLoading.value = true;
    erroCarregamento.value = null;

    try {
      const { data: sessionData } = await supabase.auth.getSession();
      temSessao.value = Boolean(sessionData?.session);

      // Sem sessão a RLS devolveria zero linhas, o que na tela é
      // indistinguível de "clínica sem pacientes". Vale parar e dizer.
      if (!temSessao.value) return;

      const { data, error } = await supabase.rpc('cards_do_quadro');
      if (error) throw error;

      cards.value = data ?? [];
    } catch (error) {
      erroCarregamento.value = error;
    } finally {
      isLoading.value = false;
    }
  };

  /**
   * Pede ao banco a progressão de fase. A decisão é do trigger `Anexo Fases`;
   * aqui só se transporta o veredito.
   *
   * @returns {Promise<{ok: boolean, error?: object}>} `error` traz o SQLSTATE
   *   em `code` e o texto oficial de bloqueio em `message`.
   */
  const moverPaciente = async (pacienteId, faseDestino) => {
    const supabase = getClient();
    if (!supabase) return { ok: false };

    const { error } = await supabase
      .from('pacientes')
      .update({ fase: faseDestino })
      .eq('id', pacienteId);

    return error ? { ok: false, error } : { ok: true };
  };

  return {
    isConfigured,
    temSessao,
    cards,
    cardsPorFase,
    isLoading,
    erroCarregamento,
    carregarCards,
    moverPaciente,
  };
}
