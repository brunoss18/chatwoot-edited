import { ref, computed } from 'vue';
import { createClient } from '@supabase/supabase-js';
import { useConfig } from 'dashboard/composables/useConfig';
import FocohSupabaseTokenAPI from 'dashboard/api/focohSupabaseToken';

/**
 * Ponte entre o board Vue e o Supabase, que é o sistema-fonte dos dados
 * clínicos. Nada de clínico é replicado no Postgres do Chatwoot.
 *
 * Autenticação: o Rails assina um JWT curto para o usuário logado, com o papel
 * clínico em `app_metadata.role` (Focoh::SupabaseTokenService). O segredo de
 * assinatura fica no servidor; aqui só circulam a anon key e o token emitido.
 *
 * O board lê exclusivamente a função `cards_do_quadro()`: ela devolve flags
 * derivados e nunca o escore de risco. Ler `avaliacoes_risco` daqui não é uma
 * questão de disciplina — a RLS não devolveria linha alguma para recepção.
 */

// Configuração de RUNTIME, servida pelo Rails em `window.chatwootConfig`
// (app/views/layouts/vueapp.html.erb) a partir de FOCOH_SUPABASE_URL e
// FOCOH_SUPABASE_ANON_KEY.
//
// Já foi build-time, via `import.meta.env.VITE_*`. O Vite gravava os valores
// dentro do bundle durante `assets:precompile`, então apontar o board para outro
// projeto Supabase exigia rebuild da imagem inteira — e, num deploy com imagem
// pré-construída, exigia secret no CI. Como runtime, basta a variável de
// ambiente e um restart.

// Renova antes do vencimento para nenhum request sair com token que expira em
// trânsito.
const MARGEM_RENOVACAO_MS = 60 * 1000;

let client = null;
let tokenCache = { token: null, expiraEmMs: 0 };
// Um board com 6 colunas dispara requests em paralelo; sem dedupe, cada um
// pediria seu próprio token ao Rails.
let emissaoPendente = null;

const emitirToken = async () => {
  const { data } = await FocohSupabaseTokenAPI.issue();
  tokenCache = {
    token: data.access_token,
    expiraEmMs: data.expires_at * 1000,
  };
  return tokenCache.token;
};

const obterToken = async () => {
  if (tokenCache.token && Date.now() < tokenCache.expiraEmMs - MARGEM_RENOVACAO_MS) {
    return tokenCache.token;
  }

  emissaoPendente = emissaoPendente || emitirToken();
  try {
    return await emissaoPendente;
  } finally {
    emissaoPendente = null;
  }
};

// Lido a cada chamada, e não uma vez no carregamento do módulo: `window` só
// existe depois que a página renderizou, e ler cedo devolveria undefined.
const getClient = () => {
  const { focohSupabaseUrl, focohSupabaseAnonKey } = useConfig();
  if (!focohSupabaseUrl || !focohSupabaseAnonKey) return null;

  if (!client) {
    // `accessToken` é o contrato do supabase-js para JWT de provedor externo:
    // ele usa este token em todo request e não tenta gerir sessão própria.
    client = createClient(focohSupabaseUrl, focohSupabaseAnonKey, {
      accessToken: obterToken,
    });
  }
  return client;
};

export function useFocohKanban() {
  const { focohSupabaseUrl, focohSupabaseAnonKey } = useConfig();

  // Ausência das variáveis é erro de deploy, não estado de operação: o board
  // mostra isso na cara do operador em vez de aparecer vazio, que pareceria
  // "nenhum paciente internado".
  const isConfigured = Boolean(focohSupabaseUrl && focohSupabaseAnonKey);

  const cards = ref([]);
  const isLoading = ref(false);
  const erroCarregamento = ref(null);
  const erroAutenticacao = ref(null);

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
    erroAutenticacao.value = null;

    try {
      // Emitido aqui, e não só dentro do callback do supabase-js, para que a
      // falta de papel clínico chegue à tela como motivo e não como erro opaco
      // de request. Sem papel, a RLS devolveria zero linhas — indistinguível
      // de "clínica sem pacientes internados".
      await obterToken();
    } catch (error) {
      erroAutenticacao.value = error.response?.data?.error ?? 'token_indisponivel';
      isLoading.value = false;
      return;
    }

    try {
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
    cards,
    cardsPorFase,
    isLoading,
    erroCarregamento,
    erroAutenticacao,
    carregarCards,
    moverPaciente,
  };
}
