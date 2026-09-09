-- ============================================================================
-- Kanban Clínico Rede Focoh — 13/15 · Gatilho 3: cobrança cronometrada
-- ----------------------------------------------------------------------------
-- Quando: toda segunda-feira 08h00, envia links parametrizados de formulário
-- aos WhatsApps corporativos de médicos e psicólogos.
-- Escalonamento: se às 12h00 ainda houver laudo pendente, alerta à Coordenação
-- Técnica para acionar contingência.
--
-- Horários em configuração, não no agendamento: o pg_cron roda esta função a
-- cada 15 minutos e ELA decide se é hora. Assim a Coordenação muda o horário
-- editando uma linha, sem reagendar cron nem fazer deploy.
--
-- Idempotência por (semana_ref, etapa): a varredura de 15 em 15 minutos passa
-- muitas vezes pela janela, e cobrança duplicada no WhatsApp de um psiquiatra
-- é o caminho mais curto para o alerta ser ignorado.
--
-- Robustez: a etapa de envio dispara em QUALQUER varredura a partir do horário
-- configurado, não só na primeira. Se o agendador estiver fora do ar às 08h00,
-- a cobrança sai às 09h00 em vez de não sair.
-- ============================================================================

create type public.etapa_cobranca as enum ('envio', 'escalonamento');

create table public.config_cobranca_laudos (
  id                          smallint primary key default 1 check (id = 1),
  dia_semana                  int not null default 1 check (dia_semana between 1 and 7),
  hora_envio                  time not null default '08:00',
  hora_escalonamento          time not null default '12:00',
  url_formulario_base         text,
  destinatarios               jsonb not null,
  destinatarios_escalonamento jsonb not null,
  ativo                       boolean not null default true,
  atualizado_em               timestamptz not null default now(),

  constraint config_cobranca_ordem_dos_horarios
    check (hora_escalonamento > hora_envio)
);

comment on table public.config_cobranca_laudos is
  'Configuração do Gatilho 3. dia_semana em ISO (1 = segunda). Horários no fuso de focoh_interno.fuso().';
comment on column public.config_cobranca_laudos.url_formulario_base is
  'Base do formulário eletrônico de laudo. NULL de propósito: apontar o formulário é ato de configuração. Sem ela a cobrança falha de forma visível em webhooks_saida.';

create trigger config_cobranca_laudos_90_touch
  before update on public.config_cobranca_laudos
  for each row execute function focoh_interno.tg_touch_atualizado_em();

insert into public.config_cobranca_laudos
  (id, destinatarios, destinatarios_escalonamento)
values (
  1,
  -- WhatsApp em branco de propósito: preencher é configuração, não código.
  jsonb_build_array(
    jsonb_build_object('tipo', 'clinico',     'funcao', 'medico_psiquiatra',   'whatsapp', null, 'ativo', true),
    jsonb_build_object('tipo', 'terapeutico', 'funcao', 'psicologo',           'whatsapp', null, 'ativo', true),
    jsonb_build_object('tipo', 'disciplinar', 'funcao', 'coordenacao_tecnica', 'whatsapp', null, 'ativo', true)
  ),
  jsonb_build_array(
    jsonb_build_object('funcao', 'coordenacao_tecnica', 'whatsapp', null, 'ativo', true)
  )
);

-- ----------------------------------------------------------------------------
-- Registro de execução — a trava de idempotência
-- ----------------------------------------------------------------------------
create table public.execucoes_cobranca_laudos (
  semana_ref       date not null,
  etapa            public.etapa_cobranca not null,
  webhooks_criados int not null default 0,
  executado_em     timestamptz not null default now(),

  primary key (semana_ref, etapa)
);

comment on table public.execucoes_cobranca_laudos is
  'Uma linha por etapa por semana. É o que impede a varredura de 15 minutos de cobrar o mesmo laudo várias vezes.';

-- ----------------------------------------------------------------------------
-- Pendências da semana vigente
-- ----------------------------------------------------------------------------
create function focoh_interno.laudos_pendentes_da_semana()
  returns table (tipo public.tipo_laudo, paciente_id uuid, paciente_nome text)
  language sql stable security definer set search_path = ''
  as $fn$
    select u.tipo_laudo, p.id, p.nome
      from public.pacientes p
     cross join pg_catalog.unnest(pg_catalog.enum_range(null::public.tipo_laudo))
           as u(tipo_laudo)
     where not p.arquivado
       and not exists (
         select 1 from public.laudos_semanais l
          where l.paciente_id = p.id
            and l.tipo        = u.tipo_laudo
            and l.semana_ref  = focoh_interno.semana_vigente()
            and l.aprovado
       )
     order by u.tipo_laudo, p.nome
  $fn$;

revoke all on function focoh_interno.laudos_pendentes_da_semana() from public;

-- ----------------------------------------------------------------------------
-- A rotina agendada
-- ----------------------------------------------------------------------------
create function focoh_interno.processar_cobranca_laudos() returns int
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_config     public.config_cobranca_laudos;
    v_agora      timestamp;
    v_semana     date := focoh_interno.semana_vigente();
    v_pendentes  int;
    v_criados    int := 0;
    v_saida_id   bigint;
    v_grupo      record;
  begin
    select * into strict v_config from public.config_cobranca_laudos where id = 1;
    if not v_config.ativo then
      return 0;
    end if;

    v_agora := pg_catalog.timezone(focoh_interno.fuso(), pg_catalog.now());

    if pg_catalog.date_part('isodow', v_agora) <> v_config.dia_semana then
      return 0;
    end if;

    select pg_catalog.count(*) into v_pendentes
      from focoh_interno.laudos_pendentes_da_semana();

    -- Etapa 1: cobrança, um webhook por tipo de laudo.
    if v_agora::time >= v_config.hora_envio
       and not exists (
         select 1 from public.execucoes_cobranca_laudos
          where semana_ref = v_semana and etapa = 'envio'
       ) then

      for v_grupo in
        select l.tipo,
               pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object(
                   'paciente_id', l.paciente_id,
                   'paciente_nome', l.paciente_nome,
                   'url', v_config.url_formulario_base
                          || '?paciente=' || l.paciente_id
                          || '&tipo=' || l.tipo
                          || '&semana=' || v_semana
                 ) order by l.paciente_nome
               ) as pacientes
          from focoh_interno.laudos_pendentes_da_semana() l
         group by l.tipo
      loop
        v_saida_id := focoh_interno.enfileirar_webhook(
          'laudos.cobranca',
          null,
          pg_catalog.jsonb_build_object(
            'evento', 'laudos.cobranca',
            'tipo_laudo', v_grupo.tipo,
            'semana_ref', v_semana,
            'destinatarios', v_config.destinatarios,
            'pacientes', v_grupo.pacientes
          )
        );
        v_criados := v_criados + 1;
      end loop;

      insert into public.execucoes_cobranca_laudos (semana_ref, etapa, webhooks_criados)
      values (v_semana, 'envio', v_criados);
    end if;

    -- Etapa 2: escalonamento à Coordenação Técnica.
    if v_agora::time >= v_config.hora_escalonamento
       and v_pendentes > 0
       and not exists (
         select 1 from public.execucoes_cobranca_laudos
          where semana_ref = v_semana and etapa = 'escalonamento'
       ) then

      v_saida_id := focoh_interno.enfileirar_webhook(
        'laudos.escalonamento',
        null,
        pg_catalog.jsonb_build_object(
          'evento', 'laudos.escalonamento',
          'semana_ref', v_semana,
          'laudos_pendentes', v_pendentes,
          'destinatarios', v_config.destinatarios_escalonamento,
          'orientacao', 'Laudos semanais ainda pendentes após o horário limite. Acionar contingência.'
        )
      );

      insert into public.execucoes_cobranca_laudos (semana_ref, etapa, webhooks_criados)
      values (v_semana, 'escalonamento', 1);

      v_criados := v_criados + 1;
    end if;

    if v_criados > 0 then
      perform focoh_interno.despachar_webhooks_pendentes(v_criados);
    end if;

    return v_criados;
  end;
  $fn$;

comment on function focoh_interno.processar_cobranca_laudos() is
  'Gatilho 3. Idempotente por (semana_ref, etapa). Chamada de 15 em 15 minutos pelo pg_cron; decide internamente se está na janela configurada.';
