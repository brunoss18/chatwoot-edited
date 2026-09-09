-- ============================================================================
-- Kanban Clínico Rede Focoh — 03/15 · tabelas, constraints e índices
-- ----------------------------------------------------------------------------
-- Nota de modelagem: os flags de laudo NÃO são colunas denormalizadas em
-- `pacientes`. Eles são derivados em `public.cards_do_quadro()` a partir de
-- `laudos_semanais`. Flag denormalizado pode ficar velho, e um flag velho aqui
-- significa liberar avanço de fase de paciente que não deveria avançar.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- pacientes — o cartão do Kanban
-- ----------------------------------------------------------------------------
create table public.pacientes (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null check (length(btrim(nome)) > 0),
  fase           public.fase_jornada not null default 'admissao_triagem',
  programa       text,
  data_admissao  date not null default focoh_interno.hoje(),
  arquivado      boolean not null default false,
  arquivado_em   timestamptz,
  -- Vigilância intensiva (UPCI). Ligada pelo Gatilho 2 (Protocolo Vermelho);
  -- declarada aqui, e não por ALTER na migration 11, para que
  -- `cards_do_quadro()` possa expô-la.
  upci_ativo     boolean not null default false,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),

  constraint pacientes_arquivado_em_coerente
    check (arquivado = (arquivado_em is not null))
);

comment on table public.pacientes is
  'Um paciente = um cartão do Kanban Clínico. `fase` é a coluna do board; só muda através da trava de avanço de fase (regra Anexo Fases).';
comment on column public.pacientes.arquivado is
  'Arquivado = desligado da jornada. Só pode virar true na coluna 6 e com Termo de Saída assinado (trava jurídica).';
comment on column public.pacientes.upci_ativo is
  'Vigilância intensiva (UPCI) ativa. Ligada pelo Protocolo Vermelho; só a equipe clínica desliga. Não é derivada do escore de propósito: risco que baixou não encerra vigilância por conta própria.';

create trigger pacientes_90_touch
  before update on public.pacientes
  for each row execute function focoh_interno.tg_touch_atualizado_em();

create index pacientes_fase_ativos_idx
  on public.pacientes (fase) where not arquivado;

create index pacientes_upci_idx
  on public.pacientes (upci_ativo) where upci_ativo;

-- ----------------------------------------------------------------------------
-- laudos_semanais — os 3 laudos da regra Anexo Fases
-- ----------------------------------------------------------------------------
create table public.laudos_semanais (
  id             uuid primary key default gen_random_uuid(),
  paciente_id    uuid not null references public.pacientes (id) on delete cascade,
  tipo           public.tipo_laudo not null,
  semana_ref     date not null,
  aprovado       boolean not null default false,
  autor          text,
  autor_user_id  uuid,
  aprovado_em    timestamptz,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),

  -- semana_ref é sempre a segunda-feira da semana de referência.
  constraint laudos_semanais_semana_na_segunda
    check (semana_ref = (date_trunc('week', semana_ref::timestamp))::date),
  constraint laudos_semanais_aprovado_em_coerente
    check (aprovado = (aprovado_em is not null)),
  constraint laudos_semanais_unico_por_semana
    unique (paciente_id, tipo, semana_ref)
);

comment on table public.laudos_semanais is
  'Laudo Clínico (médico psiquiatra), Terapêutico (psicólogo) e Disciplinar (coordenação/manejo). A trava de fase exige os 3 aprovados na semana vigente.';

create trigger laudos_semanais_90_touch
  before update on public.laudos_semanais
  for each row execute function focoh_interno.tg_touch_atualizado_em();

-- Índice que serve exatamente a pergunta da trava de fase.
create index laudos_semanais_aprovados_idx
  on public.laudos_semanais (paciente_id, semana_ref, tipo) where aprovado;

-- ----------------------------------------------------------------------------
-- config_protocolo_vermelho — limiar e destinatários EDITÁVEIS
-- ----------------------------------------------------------------------------
-- ############################################################################
-- #  AVISO DE SEGURANÇA CLÍNICA                                              #
-- #                                                                          #
-- #  O limiar de risco e os destinatários do Protocolo Vermelho devem ser     #
-- #  validados e assinados pela equipe clínica da Rede Focoh antes de         #
-- #  produção. Um alerta que falha silenciosamente é um paciente sem socorro. #
-- #                                                                          #
-- #  Os valores abaixo são os DOCUMENTADOS, não os aprovados: limiar 15 na    #
-- #  escala 1-20 e as 5 funções estratégicas, com WhatsApp em branco de       #
-- #  propósito. `validado_clinicamente` só vira true por ato humano.          #
-- ############################################################################
create table public.config_protocolo_vermelho (
  id                    smallint primary key default 1 check (id = 1),
  limiar_moderado       int not null default 15 check (limiar_moderado between 1 and 20),
  limiar_alto           int check (limiar_alto between 1 and 20),
  destinatarios         jsonb not null,
  validado_clinicamente boolean not null default false,
  validado_por          text,
  validado_em           timestamptz,
  atualizado_em         timestamptz not null default now(),

  constraint config_pv_limiares_coerentes
    check (limiar_alto is null or limiar_alto >= limiar_moderado),
  constraint config_pv_validacao_rastreavel
    check (not validado_clinicamente
           or (validado_por is not null and validado_em is not null))
);

comment on table public.config_protocolo_vermelho is
  'Configuração do Protocolo Vermelho / UPCI. Singleton (id = 1). Limiar e destinatários NÃO são hard-coded: são dados editáveis pela Coordenação Técnica / Direção.';
comment on column public.config_protocolo_vermelho.limiar_moderado is
  'Escore a partir do qual o risco é classificado Moderado e o Protocolo Vermelho dispara. Valor documentado: 15 (escala 1-20). Requer assinatura clínica.';
comment on column public.config_protocolo_vermelho.limiar_alto is
  'Escore a partir do qual o risco é Alto. NULL porque a documentação Rede Focoh não define este corte. Enquanto NULL, nada é classificado Alto automaticamente — sem lacuna de segurança, porque Moderado já dispara o Protocolo Vermelho e já barra avanço de fase.';
comment on column public.config_protocolo_vermelho.validado_clinicamente is
  'Trava de governança: false até a equipe clínica da Rede Focoh assinar limiar e destinatários. O deploy de produção deve checar este campo.';

create trigger config_protocolo_vermelho_90_touch
  before update on public.config_protocolo_vermelho
  for each row execute function focoh_interno.tg_touch_atualizado_em();

insert into public.config_protocolo_vermelho (id, limiar_moderado, limiar_alto, destinatarios)
values (
  1,
  15,
  null,
  -- Funções estratégicas da documentação. `whatsapp` em branco de propósito:
  -- preencher é ato de configuração, não de código.
  jsonb_build_array(
    jsonb_build_object('funcao', 'medico_psiquiatra_referencia', 'whatsapp', null, 'ativo', true),
    jsonb_build_object('funcao', 'enfermeiro_responsavel_tecnico', 'whatsapp', null, 'ativo', true),
    jsonb_build_object('funcao', 'coordenacao_tecnica', 'whatsapp', null, 'ativo', true),
    jsonb_build_object('funcao', 'gerente_familias_do_caso', 'whatsapp', null, 'ativo', true),
    jsonb_build_object('funcao', 'diretor_geral', 'whatsapp', null, 'ativo', true)
  )
);

-- ----------------------------------------------------------------------------
-- avaliacoes_risco — TABELA SENSÍVEL (escore de risco de suicídio)
-- ----------------------------------------------------------------------------
-- Isolamento: RLS restrita à equipe clínica (migration 08). O board NUNCA lê
-- esta tabela; ele lê `public.cards_do_quadro()`, que devolve apenas flags.
-- ----------------------------------------------------------------------------
create table public.avaliacoes_risco (
  id                uuid primary key default gen_random_uuid(),
  paciente_id       uuid not null references public.pacientes (id) on delete cascade,
  escore            int not null check (escore between 1 and 20),
  nivel             public.nivel_risco not null,
  ativo             boolean not null default true,
  ideacao_detalhes  text,
  avaliado_por      uuid,
  avaliado_em       timestamptz not null default now(),
  criado_em         timestamptz not null default now()
);

comment on table public.avaliacoes_risco is
  'DADO SENSÍVEL. Ficha de Avaliação de Risco de Suicídio (escala 1-20). Acesso restrito por RLS à equipe clínica. Nunca expor escore nem ideacao_detalhes ao cartão do Kanban.';
comment on column public.avaliacoes_risco.nivel is
  'Derivado do escore pelos limiares de config_protocolo_vermelho (trigger na migration 03). Não aceita valor do cliente: escore e nível nunca podem divergir.';
comment on column public.avaliacoes_risco.ativo is
  'Avaliação vigente. Só uma por paciente (índice único parcial).';

-- Uma única avaliação vigente por paciente.
create unique index avaliacoes_risco_uma_ativa_por_paciente_idx
  on public.avaliacoes_risco (paciente_id) where ativo;

create index avaliacoes_risco_paciente_idx
  on public.avaliacoes_risco (paciente_id, avaliado_em desc);

-- ----------------------------------------------------------------------------
-- termos_saida — alimenta a trava de saída jurídica (coluna 6)
-- ----------------------------------------------------------------------------
create table public.termos_saida (
  id             uuid primary key default gen_random_uuid(),
  paciente_id    uuid not null references public.pacientes (id) on delete cascade,
  tipo           public.tipo_termo_saida not null,
  pdf_url        text,
  assinado       boolean not null default false,
  assinado_em    timestamptz,
  enviado_por    uuid,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),

  -- Núcleo da trava jurídica: "assinado" sem PDF é estado impossível.
  constraint termos_saida_assinado_exige_pdf
    check (not assinado or (pdf_url is not null and length(btrim(pdf_url)) > 0)),
  constraint termos_saida_assinado_em_coerente
    check (assinado = (assinado_em is not null))
);

comment on table public.termos_saida is
  'Termos de saída da coluna 6. A constraint termos_saida_assinado_exige_pdf garante que `assinado` implica PDF anexado, então a trava de arquivamento pode confiar só em `assinado`.';

create trigger termos_saida_90_touch
  before update on public.termos_saida
  for each row execute function focoh_interno.tg_touch_atualizado_em();

create index termos_saida_assinados_idx
  on public.termos_saida (paciente_id) where assinado;

-- ----------------------------------------------------------------------------
-- agendamentos_visita — regra do bloqueio de visitas por 30 dias
-- ----------------------------------------------------------------------------
create table public.agendamentos_visita (
  id             uuid primary key default gen_random_uuid(),
  paciente_id    uuid not null references public.pacientes (id) on delete cascade,
  data_visita    date not null,
  visitante      text not null check (length(btrim(visitante)) > 0),
  cancelado      boolean not null default false,
  criado_por     uuid,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

comment on table public.agendamentos_visita is
  'Agendamento de visita. Bloqueado nos primeiros 30 dias de internação (trigger na migration 06).';

create trigger agendamentos_visita_90_touch
  before update on public.agendamentos_visita
  for each row execute function focoh_interno.tg_touch_atualizado_em();

create index agendamentos_visita_paciente_idx
  on public.agendamentos_visita (paciente_id, data_visita) where not cancelado;

-- ----------------------------------------------------------------------------
-- auditoria_transicoes_fase
-- ----------------------------------------------------------------------------
-- Registra APENAS transições efetivadas. Tentativa bloqueada levanta exceção,
-- e a exceção desfaz a transação — um INSERT de auditoria feito antes do RAISE
-- seria revertido junto. Tentativa bloqueada é registrada via RAISE WARNING no
-- log do Postgres (migration 04); a persistência de tentativas negadas fica
-- para o ponto de extensão de webhook do passo 4, fora da transação.
-- ----------------------------------------------------------------------------
create table public.auditoria_transicoes_fase (
  id            bigint generated always as identity primary key,
  paciente_id   uuid not null references public.pacientes (id) on delete cascade,
  fase_origem   public.fase_jornada not null,
  fase_destino  public.fase_jornada not null,
  regressao     boolean not null,
  papel_ator    text,
  ator_user_id  uuid,
  ocorrido_em   timestamptz not null default now()
);

create index auditoria_transicoes_fase_paciente_idx
  on public.auditoria_transicoes_fase (paciente_id, ocorrido_em desc);

-- ----------------------------------------------------------------------------
-- Colunas de autoria
-- ----------------------------------------------------------------------------
-- Guardam o claim `sub` do JWT, e NÃO têm FK para `auth.users`: a identidade
-- vem do Chatwoot, que emite o token no backend (Focoh::SupabaseTokenService).
-- Nesse arranjo o Supabase Auth não é o provedor, então não existe linha em
-- `auth.users` para referenciar — uma FK ali quebraria todo insert com autoria.
--
-- O `sub` é um UUIDv5 derivado do id do usuário Chatwoot: estável entre sessões
-- e reproduzível, o que mantém a auditoria rastreável sem FK.
-- ----------------------------------------------------------------------------
comment on column public.laudos_semanais.autor_user_id is
  'Claim `sub` do JWT (UUIDv5 do usuário Chatwoot) de quem aprovou o laudo.';
comment on column public.avaliacoes_risco.avaliado_por is
  'Claim `sub` do JWT (UUIDv5 do usuário Chatwoot) de quem lançou a ficha de risco.';
comment on column public.termos_saida.enviado_por is
  'Claim `sub` do JWT (UUIDv5 do usuário Chatwoot) de quem anexou o termo.';
comment on column public.agendamentos_visita.criado_por is
  'Claim `sub` do JWT (UUIDv5 do usuário Chatwoot) de quem agendou a visita.';
