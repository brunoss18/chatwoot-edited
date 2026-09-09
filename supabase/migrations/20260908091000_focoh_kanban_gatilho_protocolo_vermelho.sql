-- ============================================================================
-- Kanban Clínico Rede Focoh — 12/15 · Gatilho 2: PROTOCOLO VERMELHO / UPCI
-- ============================================================================
-- ############################################################################
-- #  AVISO DE SEGURANÇA CLÍNICA                                              #
-- #                                                                          #
-- #  O limiar de risco e os destinatários do Protocolo Vermelho devem ser     #
-- #  validados e assinados pela equipe clínica da Rede Focoh antes de         #
-- #  produção. Um alerta que falha silenciosamente é um paciente sem socorro. #
-- #                                                                          #
-- #  O limiar vive em config_protocolo_vermelho.limiar_moderado (valor        #
-- #  documentado: 15, escala 1-20) e os destinatários em .destinatarios —     #
-- #  ambos EDITÁVEIS. Não há limiar nem telefone escrito neste arquivo.       #
-- #  `validado_clinicamente` só vira true por ato humano.                     #
-- ############################################################################
--
-- Quando: lançamento da Ficha de Avaliação de Risco de Suicídio cujo escore
-- atinge o limiar configurado (nível derivado Moderado ou Alto).
--
-- Ação: notificação silenciosa de emergência às funções estratégicas e
-- sinalização do paciente para vigilância intensiva (UPCI).
--
-- O QUE NÃO VAI NO PAYLOAD: escore, nível e detalhes de ideação. WhatsApp é
-- canal inseguro e encaminhável. "Protocolo Vermelho" já comunica a urgência
-- máxima; a gravidade se consulta no sistema, sob RLS. A auditoria guarda o
-- vínculo com a ficha (avaliacao_id), não uma segunda cópia do escore.
-- ============================================================================

-- `pacientes.upci_ativo` é declarada na migration 02, junto da tabela, para que
-- `cards_do_quadro()` (migration 07) possa expô-la.

-- ----------------------------------------------------------------------------
-- Só a equipe clínica DESLIGA a vigilância intensiva
--
-- A RLS de `pacientes` é por linha, não por coluna: sem este guarda, a mesma
-- policy que deixa a recepção arrastar cartão deixaria a recepção desligar a
-- UPCI de um paciente em Protocolo Vermelho.
--
-- O guarda cobre só o desligamento. Ligar é ato automático do Gatilho 2, que
-- roda no contexto de quem lançou a ficha de risco (e também do seed e de
-- rotinas de serviço) — exigir papel clínico para ligar bloquearia o próprio
-- alerta que esta migration existe para garantir.
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_pacientes_guarda_upci() returns trigger
  language plpgsql set search_path = ''
  as $fn$
  begin
    if not (old.upci_ativo and not new.upci_ativo) then
      return new;
    end if;

    if not focoh_interno.e_equipe_clinica() then
      raise exception 'Encerrar a vigilância intensiva (UPCI) é decisão clínica e exige papel da equipe clínica.'
        using errcode = 'FCH08';
    end if;

    return new;
  end;
  $fn$;

-- 30: depois das travas de fase (10) e de saída jurídica (20).
create trigger pacientes_30_guarda_upci
  before update on public.pacientes
  for each row execute function focoh_interno.tg_pacientes_guarda_upci();

-- ----------------------------------------------------------------------------
-- Auditoria de disparo
-- ----------------------------------------------------------------------------
create table public.protocolo_vermelho_disparos (
  id               bigint generated always as identity primary key,
  paciente_id      uuid not null references public.pacientes (id) on delete cascade,
  avaliacao_id     uuid not null references public.avaliacoes_risco (id) on delete cascade,
  nivel            public.nivel_risco not null,
  limiar_aplicado  int not null,
  destinatarios    jsonb not null,
  webhook_saida_id bigint references public.webhooks_saida (id) on delete set null,
  disparado_em     timestamptz not null default now(),

  constraint pv_disparos_nivel_de_risco_ativo
    check (nivel <> 'baixo')
);

comment on table public.protocolo_vermelho_disparos is
  'Auditoria de cada disparo do Protocolo Vermelho. `limiar_aplicado` e `destinatarios` são snapshots do momento: se a config mudar depois, ainda se sabe qual regra valia. A falha de entrega é auditada em webhooks_saida, via webhook_saida_id.';
comment on column public.protocolo_vermelho_disparos.destinatarios is
  'Snapshot de quem DEVIA receber. Comparado com o estado do webhook, responde "o alerta chegou a quem tinha de chegar?".';

create index pv_disparos_paciente_idx
  on public.protocolo_vermelho_disparos (paciente_id, disparado_em desc);

-- ----------------------------------------------------------------------------
-- O gatilho
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_avaliacoes_risco_protocolo_vermelho() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_config    public.config_protocolo_vermelho;
    v_paciente  public.pacientes;
    v_saida_id  bigint;
  begin
    if new.nivel = 'baixo' or not new.ativo then
      return null;
    end if;

    -- Config é registro obrigatório de produção. Falhar aqui é melhor que
    -- disparar (ou não disparar) com regra inventada.
    select * into strict v_config from public.config_protocolo_vermelho where id = 1;
    select * into v_paciente from public.pacientes where id = new.paciente_id;

    update public.pacientes set upci_ativo = true where id = new.paciente_id;

    v_saida_id := focoh_interno.enfileirar_webhook(
      'protocolo_vermelho.disparo',
      new.paciente_id,
      pg_catalog.jsonb_build_object(
        'evento', 'protocolo_vermelho.disparo',
        'paciente_id', new.paciente_id,
        'paciente_nome', v_paciente.nome,
        'programa', v_paciente.programa,
        'fase', v_paciente.fase,
        'upci', true,
        -- Sem escore, sem nível, sem ideação: ver cabeçalho.
        'orientacao', 'Protocolo Vermelho ativado. Paciente sinalizado para vigilância intensiva (UPCI). Consulte o sistema para os detalhes clínicos.',
        'destinatarios', v_config.destinatarios,
        'disparado_em', pg_catalog.now()
      )
    );

    insert into public.protocolo_vermelho_disparos
      (paciente_id, avaliacao_id, nivel, limiar_aplicado, destinatarios, webhook_saida_id)
    values
      (new.paciente_id, new.id, new.nivel, v_config.limiar_moderado,
       v_config.destinatarios, v_saida_id);

    -- Alerta de risco de suicídio não espera ciclo de cron.
    perform focoh_interno.despachar_webhook(v_saida_id);

    -- Vai para o log do Postgres mesmo que o transporte falhe depois.
    raise warning 'Kanban Focoh: PROTOCOLO VERMELHO paciente=% avaliacao=% webhook=%',
      new.paciente_id, new.id, v_saida_id;

    return null;
  end;
  $fn$;

comment on function focoh_interno.tg_avaliacoes_risco_protocolo_vermelho() is
  'Gatilho 2. Enfileira o alerta na mesma transação da ficha de risco, audita o disparo e liga a UPCI. Limiar e destinatários vêm da config editável.';

-- 30: depois de derivar o nível (10) e desativar a ficha anterior (20).
create trigger avaliacoes_risco_30_protocolo_vermelho
  after insert on public.avaliacoes_risco
  for each row execute function focoh_interno.tg_avaliacoes_risco_protocolo_vermelho();

-- ----------------------------------------------------------------------------
-- Vigilância operacional: alertas que NÃO chegaram
-- ----------------------------------------------------------------------------
-- Esta view é o painel que responde à frase do aviso. Se ela tem linha, existe
-- paciente cujo Protocolo Vermelho foi ordenado e não se comprovou entrega.
-- ----------------------------------------------------------------------------
create view public.protocolo_vermelho_alertas_nao_entregues
  with (security_invoker = true)
  as
  select d.id            as disparo_id,
         d.paciente_id,
         p.nome          as paciente_nome,
         d.disparado_em,
         s.id            as webhook_saida_id,
         s.estado,
         s.tentativas,
         s.ultimo_erro
    from public.protocolo_vermelho_disparos d
    join public.pacientes p on p.id = d.paciente_id
    left join public.webhooks_saida s on s.id = d.webhook_saida_id
   where s.id is null
      or s.estado <> 'enviado'
   order by d.disparado_em desc;

comment on view public.protocolo_vermelho_alertas_nao_entregues is
  'Disparos do Protocolo Vermelho sem entrega comprovada. Linha nesta view = paciente possivelmente sem socorro; monitorar em produção. security_invoker: respeita a RLS de quem consulta.';
