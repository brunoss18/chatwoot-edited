-- ============================================================================
-- Kanban Clínico Rede Focoh — 01/08 · enums, schema interno e helpers
-- ----------------------------------------------------------------------------
-- Fonte funcional: documentação oficial Rede Focoh ("Jornada do Paciente",
-- "Anexo Fases", "Protocolos Automáticos de Segurança").
--
-- PRINCÍPIO ARQUITETURAL: toda trava clínica vive aqui, no banco. O board Vue
-- apenas reflete o que estas regras permitem — nenhuma decisão clínica é
-- tomada no frontend, porque qualquer request direto à API PostgREST o
-- contornaria.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Schema interno
-- ----------------------------------------------------------------------------
create schema if not exists focoh_interno;

comment on schema focoh_interno is
  'Internals do Kanban Clínico (helpers de papel, funções de trava, leitura do escore de risco). NUNCA adicionar este schema aos "Exposed schemas" do PostgREST: ele contém funções que leem a tabela sensível avaliacoes_risco.';

revoke all on schema focoh_interno from public;
-- As policies de RLS são avaliadas com os privilégios de quem consulta,
-- portanto `authenticated` precisa resolver os helpers de papel.
grant usage on schema focoh_interno to authenticated;

-- ----------------------------------------------------------------------------
-- Enum das 6 colunas da jornada
--
-- A ORDEM DE DECLARAÇÃO É A ORDEM DA JORNADA: o Postgres ordena enums pela
-- declaração, então `fase_a < fase_b` já significa "vem antes na jornada".
-- Não reordenar sem migration de dados.
--
--  1 Admissão e Triagem Inicial              — acolhimento, triagem, escala de risco, termos jurídicos  (até 72h)
--  2 Fase 1 - Autocrítica e Aceitação        — redução da negação, estabilização neurobiológica         (3-6 sem)
--  3 Fase 2 - Disciplina e Projeto de Vida   — rotina, rondas 2/2h, Mapa do Projeto de Vida             (4-8 sem)
--  4 Fase 3 - Empatia e Autocuidado          — sustentação emocional, retomada de visitas               (4-8 sem)
--  5 Fase 4 - Identidade, Sustentação e Pré-Alta — autonomia, Plano de Prevenção a Recaídas (90 dias)   (2-4 sem)
--  6 Alta Hospitalar e Transição AMANDA      — desligamento seguro, termos de saída, pós-alta           (—)
--
-- Rótulos, emojis e cores ficam no i18n do frontend, não no banco.
-- ----------------------------------------------------------------------------
create type public.fase_jornada as enum (
  'admissao_triagem',
  'fase1_autocritica',
  'fase2_disciplina',
  'fase3_empatia',
  'fase4_identidade',
  'alta_transicao'
);

-- Os 3 Laudos Semanais da regra "Anexo Fases".
create type public.tipo_laudo as enum ('clinico', 'terapeutico', 'disciplinar');

create type public.nivel_risco as enum ('baixo', 'moderado', 'alto');

-- Termos de saída aceitos pela trava jurídica da coluna 6.
create type public.tipo_termo_saida as enum (
  'conclusiva',
  'administrativa',
  'a_pedido',
  'a_pedido_involuntariedade_familiar'
);

-- Estado agregado exibido no cartão. Deliberadamente grosseiro:
-- 'pendencia_clinica' cobre risco moderado E alto, para que o cartão (visível a
-- atendimento/recepção) não permita inferir a gravidade nem o escore.
create type public.nivel_pendencia_card as enum (
  'nenhuma',
  'laudos_pendentes',
  'pendencia_clinica',
  'sem_avaliacao_risco'
);

-- ----------------------------------------------------------------------------
-- Tempo institucional
-- ----------------------------------------------------------------------------
create function focoh_interno.fuso() returns text
  language sql immutable parallel safe set search_path = ''
  as $fn$ select 'America/Sao_Paulo'::text $fn$;

comment on function focoh_interno.fuso() is
  'Fuso das clínicas. Define a virada da "semana vigente" dos laudos e o horário da cobrança de segunda-feira 08h00.';

create function focoh_interno.hoje() returns date
  language sql stable parallel safe set search_path = ''
  as $fn$ select (pg_catalog.timezone(focoh_interno.fuso(), pg_catalog.now()))::date $fn$;

-- Segunda-feira da semana corrente: é o `semana_ref` que a trava de fase exige.
create function focoh_interno.semana_vigente() returns date
  language sql stable parallel safe set search_path = ''
  as $fn$ select (pg_catalog.date_trunc('week', focoh_interno.hoje()::timestamp))::date $fn$;

comment on function focoh_interno.semana_vigente() is
  'Segunda-feira da semana corrente. A trava de avanço de fase só aceita laudos com semana_ref igual a este valor: laudo da semana passada não libera fase.';

-- ----------------------------------------------------------------------------
-- Ordem da jornada
-- ----------------------------------------------------------------------------
create function focoh_interno.fase_ordem(p_fase public.fase_jornada) returns int
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select pg_catalog.array_position(
             pg_catalog.enum_range(null::public.fase_jornada), p_fase)
  $fn$;

-- ----------------------------------------------------------------------------
-- Papel clínico do usuário autenticado
--
-- O papel vem do JWT do Supabase em `app_metadata.role` (não é o role do
-- Postgres — todo usuário logado é `authenticated`). `service_role` tem
-- BYPASSRLS e é usado apenas por jobs/edge functions.
-- ----------------------------------------------------------------------------
create function focoh_interno.papel_atual() returns text
  language sql stable parallel safe set search_path = ''
  as $fn$ select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') $fn$;

create function focoh_interno.papeis_focoh() returns text[]
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select array[
      'recepcao',              -- atendimento/recepção: vê o board e move cartões
      'gerente_familias',      -- Gerente de Famílias do Caso
      'medico_psiquiatra',     -- Médico Psiquiatra de Referência
      'psicologo',
      'enfermeiro_rt',         -- Enfermeiro Responsável Técnico
      'coordenacao_tecnica',
      'diretor_geral'
    ]::text[]
  $fn$;

-- Quem pode ler o ESCORE de risco de suicídio. Recepção e Gerente de Famílias
-- ficam fora por propósito: eles recebem o flag do Protocolo Vermelho, não o número.
create function focoh_interno.papeis_equipe_clinica() returns text[]
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select array[
      'medico_psiquiatra',
      'psicologo',
      'enfermeiro_rt',
      'coordenacao_tecnica',
      'diretor_geral'
    ]::text[]
  $fn$;

comment on function focoh_interno.papeis_equipe_clinica() is
  'PENDENTE DE VALIDAÇÃO CLÍNICA: a composição da "equipe clínica" com acesso ao escore de risco deve ser assinada pela Rede Focoh antes de produção.';

create function focoh_interno.e_staff() returns boolean
  language sql stable parallel safe set search_path = ''
  as $fn$ select focoh_interno.papel_atual() = any(focoh_interno.papeis_focoh()) $fn$;

create function focoh_interno.e_equipe_clinica() returns boolean
  language sql stable parallel safe set search_path = ''
  as $fn$ select focoh_interno.papel_atual() = any(focoh_interno.papeis_equipe_clinica()) $fn$;

-- Mapa "quem aprova qual laudo" da regra Anexo Fases.
create function focoh_interno.papeis_aprovadores_laudo(p_tipo public.tipo_laudo)
  returns text[]
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select case p_tipo
      when 'clinico'     then array['medico_psiquiatra']      -- médico psiquiatra
      when 'terapeutico' then array['psicologo']              -- psicólogo
      when 'disciplinar' then array['coordenacao_tecnica']    -- coordenação/manejo
    end::text[]
  $fn$;

-- ----------------------------------------------------------------------------
-- Textos oficiais de bloqueio
--
-- O frontend exibe a mensagem que vem no erro do banco (uma única fonte de
-- verdade); as chaves de i18n servem apenas de fallback.
-- ----------------------------------------------------------------------------
create function focoh_interno.msg_avanco_bloqueado() returns text
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select 'Avanço Bloqueado: A transição de fase exige a aprovação dos 3 Laudos Semanais (Clínico, Terapêutico e Disciplinar) e a ausência de riscos ativos. Verifique as pendências com a Coordenação Técnica.'::text
  $fn$;

comment on function focoh_interno.msg_avanco_bloqueado() is
  'Texto oficial Rede Focoh. Não editar sem aprovação da Coordenação Técnica.';

create function focoh_interno.msg_arquivamento_bloqueado() returns text
  language sql immutable parallel safe set search_path = ''
  as $fn$
    select 'Arquivamento Bloqueado: a Alta Hospitalar exige o upload do PDF assinado do Termo de Saída correspondente (Alta Conclusiva, Alta Administrativa, Alta a Pedido ou Alta a Pedido em Involuntariedade por Familiar). Anexe o termo assinado para concluir o desligamento.'::text
  $fn$;

comment on function focoh_interno.msg_arquivamento_bloqueado() is
  'AGUARDANDO TEXTO OFICIAL: redação provisória. A documentação Rede Focoh define a regra da trava jurídica mas não fornece a copy; validar com a Coordenação Técnica.';

-- ----------------------------------------------------------------------------
-- Utilitário de timestamp
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_touch_atualizado_em() returns trigger
  language plpgsql set search_path = ''
  as $fn$
  begin
    new.atualizado_em := pg_catalog.now();
    return new;
  end;
  $fn$;
