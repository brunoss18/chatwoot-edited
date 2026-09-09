-- ============================================================================
-- Kanban Clínico Rede Focoh — 10/15 · infraestrutura de webhooks (outbox)
-- ----------------------------------------------------------------------------
-- Os quatro Protocolos Automáticos de Segurança emitem webhook. O que garante
-- que nenhum alerta se perca sem rastro NÃO é o transporte HTTP, é este outbox:
-- o trigger grava a ordem de saída na MESMA transação do evento clínico. Se a
-- ficha de risco existe, a ordem de alerta existe. Se a transação volta atrás,
-- as duas voltam juntas.
--
-- O transporte fica isolado em `focoh_interno.despachar_webhook(id)`. Trocar
-- pg_net por Edge Function é reescrever aquela função — trigger, auditoria e
-- teste não mudam.
--
-- Ponto de extensão: quem RECEBE. Cada evento aponta para uma URL em
-- `config_webhooks`; o corpo é o `payload` da linha, em POST JSON.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Estados de uma saída
--
-- `em_transito` existe porque pg_net é assíncrono: o http_post devolve um
-- request_id e a resposta chega depois, em net._http_response. Sem este estado
-- não haveria como distinguir "não tentado" de "tentado, resposta desconhecida"
-- — e essa diferença é exatamente o que separa um alerta pendente de um alerta
-- possivelmente perdido.
-- ----------------------------------------------------------------------------
create type public.estado_webhook as enum (
  'pendente',
  'em_transito',
  'enviado',
  'falhou'
);

create type public.evento_webhook as enum (
  'copa.restricao_alimentar',
  'protocolo_vermelho.disparo',
  'laudos.cobranca',
  'laudos.escalonamento'
);

-- ----------------------------------------------------------------------------
-- config_webhooks — endpoints, editáveis
-- ----------------------------------------------------------------------------
-- CONTÉM SEGREDO: `headers` carrega o cabeçalho de autenticação do endpoint
-- receptor. A RLS (migration 14) restringe leitura à Direção. Em produção,
-- prefira guardar o token no Supabase Vault e referenciá-lo aqui.
-- ----------------------------------------------------------------------------
create table public.config_webhooks (
  evento         public.evento_webhook primary key,
  url            text,
  headers        jsonb not null default '{"Content-Type": "application/json"}'::jsonb,
  ativo          boolean not null default true,
  max_tentativas int not null default 5 check (max_tentativas between 1 and 20),
  timeout_ms     int not null default 5000 check (timeout_ms between 1000 and 30000),
  atualizado_em  timestamptz not null default now()
);

comment on table public.config_webhooks is
  'Destino de cada Protocolo Automático de Segurança. URL nasce NULL de propósito: apontar o endpoint é ato de configuração, não de código.';

create trigger config_webhooks_90_touch
  before update on public.config_webhooks
  for each row execute function focoh_interno.tg_touch_atualizado_em();

insert into public.config_webhooks (evento) values
  ('copa.restricao_alimentar'),
  ('protocolo_vermelho.disparo'),
  ('laudos.cobranca'),
  ('laudos.escalonamento');

-- ----------------------------------------------------------------------------
-- webhooks_saida — o outbox
-- ----------------------------------------------------------------------------
create table public.webhooks_saida (
  id             bigint generated always as identity primary key,
  evento         public.evento_webhook not null,
  paciente_id    uuid references public.pacientes (id) on delete set null,
  payload        jsonb not null,
  estado         public.estado_webhook not null default 'pendente',
  tentativas     int not null default 0,
  request_id     bigint,
  ultimo_erro    text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  enviado_em     timestamptz,

  constraint webhooks_saida_enviado_em_coerente
    check ((estado = 'enviado') = (enviado_em is not null))
);

comment on table public.webhooks_saida is
  'Outbox dos gatilhos automáticos. Uma linha aqui é a prova de que o alerta foi ordenado; `estado` diz se saiu. Alerta que falhou permanece visível, não desaparece.';

create trigger webhooks_saida_90_touch
  before update on public.webhooks_saida
  for each row execute function focoh_interno.tg_touch_atualizado_em();

-- Fila de despacho e de reconciliação.
create index webhooks_saida_pendentes_idx
  on public.webhooks_saida (criado_em) where estado = 'pendente';
create index webhooks_saida_em_transito_idx
  on public.webhooks_saida (request_id) where estado = 'em_transito';
create index webhooks_saida_falhas_idx
  on public.webhooks_saida (evento, atualizado_em desc) where estado = 'falhou';

-- ----------------------------------------------------------------------------
-- enfileirar_webhook — chamada pelos triggers
-- ----------------------------------------------------------------------------
create function focoh_interno.enfileirar_webhook(
  p_evento      public.evento_webhook,
  p_paciente_id uuid,
  p_payload     jsonb
) returns bigint
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_id bigint;
  begin
    insert into public.webhooks_saida (evento, paciente_id, payload)
    values (p_evento, p_paciente_id, p_payload)
    returning id into v_id;

    return v_id;
  end;
  $fn$;

revoke all on function focoh_interno.enfileirar_webhook(public.evento_webhook, uuid, jsonb) from public;

-- ----------------------------------------------------------------------------
-- despachar_webhook — o transporte, isolado numa função só
-- ----------------------------------------------------------------------------
-- Trocar pg_net por Edge Function / fila externa é reescrever ESTA função.
-- Nada mais no módulo sabe como o HTTP acontece.
--
-- pg_net enfileira o request de forma transacional: se a transação que chamou
-- aqui voltar atrás, o POST não sai. É o comportamento correto — não se alerta
-- sobre uma ficha de risco que não foi gravada.
-- ----------------------------------------------------------------------------
create function focoh_interno.despachar_webhook(p_id bigint) returns void
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_saida  public.webhooks_saida;
    v_config public.config_webhooks;
    v_request_id bigint;
  begin
    select * into v_saida from public.webhooks_saida where id = p_id for update;
    if v_saida.estado <> 'pendente' then
      return;
    end if;

    select * into v_config from public.config_webhooks where evento = v_saida.evento;

    -- Endpoint ausente não pode virar retry silencioso eterno: marca falha,
    -- que é o que a view de alertas não entregues enxerga.
    if v_config.url is null or not v_config.ativo then
      update public.webhooks_saida
         set estado      = 'falhou',
             tentativas  = tentativas + 1,
             ultimo_erro = case
               when v_config.url is null then 'endpoint_nao_configurado'
               else 'endpoint_desativado'
             end
       where id = p_id;

      raise warning 'Kanban Focoh: webhook % (%) sem endpoint utilizável', p_id, v_saida.evento;
      return;
    end if;

    v_request_id := net.http_post(
      url                 := v_config.url,
      body                := v_saida.payload,
      headers             := v_config.headers,
      timeout_milliseconds := v_config.timeout_ms
    );

    update public.webhooks_saida
       set estado     = 'em_transito',
           tentativas = tentativas + 1,
           request_id = v_request_id
     where id = p_id;
  end;
  $fn$;

revoke all on function focoh_interno.despachar_webhook(bigint) from public;

-- ----------------------------------------------------------------------------
-- despachar_webhooks_pendentes — varredura agendada (pg_cron)
-- ----------------------------------------------------------------------------
-- O Protocolo Vermelho NÃO depende desta varredura: seu trigger despacha na
-- hora. Isto aqui é a rede de segurança dos eventos menos urgentes e dos
-- reenfileirados por falha.
-- ----------------------------------------------------------------------------
create function focoh_interno.despachar_webhooks_pendentes(p_limite int default 50)
  returns int
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_id    bigint;
    v_total int := 0;
  begin
    for v_id in
      select id from public.webhooks_saida
       where estado = 'pendente'
       order by criado_em
       limit p_limite
    loop
      perform focoh_interno.despachar_webhook(v_id);
      v_total := v_total + 1;
    end loop;

    return v_total;
  end;
  $fn$;

-- ----------------------------------------------------------------------------
-- reconciliar_webhooks — fecha o ciclo de auditoria de ENTREGA
-- ----------------------------------------------------------------------------
-- Sem isto, `em_transito` seria um limbo permanente e "falha de entrega" nunca
-- seria auditável — que é justamente o que a Rede Focoh precisa enxergar.
--
-- pg_net expira as respostas em net._http_response depois de algumas horas.
-- Uma saída que ficou em trânsito além disso é tratada como falha, porque
-- resposta que não se pode mais verificar não é entrega comprovada.
-- ----------------------------------------------------------------------------
create function focoh_interno.reconciliar_webhooks() returns int
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_total int := 0;
  begin
    with respondidos as (
      select s.id,
             s.tentativas,
             c.max_tentativas,
             r.status_code,
             r.error_msg
        from public.webhooks_saida s
        join public.config_webhooks c on c.evento = s.evento
        join net._http_response r on r.id = s.request_id
       where s.estado = 'em_transito'
    )
    update public.webhooks_saida s
       set estado = case
             when d.status_code between 200 and 299 then 'enviado'::public.estado_webhook
             when d.tentativas < d.max_tentativas   then 'pendente'::public.estado_webhook
             else 'falhou'::public.estado_webhook
           end,
           enviado_em = case
             when d.status_code between 200 and 299 then pg_catalog.now()
           end,
           ultimo_erro = case
             when d.status_code between 200 and 299 then null
             else coalesce(d.error_msg, 'http_status=' || d.status_code)
           end,
           request_id = case
             when d.status_code between 200 and 299 then s.request_id
             else null
           end
      from respondidos d
     where s.id = d.id;

    get diagnostics v_total = row_count;

    -- Em trânsito há mais de 6h sem resposta localizável: o registro do pg_net
    -- já expirou, então não há como comprovar entrega.
    update public.webhooks_saida
       set estado      = 'falhou',
           ultimo_erro = 'resposta_expirada_sem_confirmacao'
     where estado = 'em_transito'
       and atualizado_em < pg_catalog.now() - interval '6 hours';

    return v_total;
  end;
  $fn$;
