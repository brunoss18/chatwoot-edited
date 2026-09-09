-- ============================================================================
-- Stubs de pg_net e pg_cron para o harness offline
-- ----------------------------------------------------------------------------
-- O Postgres em WASM não instala extensões nativas, então o runner pula a
-- migration 01 (extensões) e carrega isto no lugar.
--
-- FRONTEIRA DO TESTE, explícita: com estes stubs o harness prova que o gatilho
-- ORDENA o alerta (linha em webhooks_saida), que o payload não leva escore, que
-- a auditoria registra o disparo e que a falha de entrega fica visível. Ele NÃO
-- prova que um POST atravessa a internet — isso depende do endpoint real e é
-- verificação de ambiente, não de regra clínica.
--
-- A garantia que importa é a primeira: o outbox é gravado na mesma transação da
-- ficha de risco, e isso é Postgres puro, sem stub nenhum no caminho.
-- ============================================================================

create schema net;

-- Registro do que o pg_net teria enviado. O teste inspeciona esta tabela.
create table net.requisicoes_stub (
  id                   bigint generated always as identity primary key,
  destino              text,
  corpo                jsonb,
  cabecalhos           jsonb,
  timeout_ms           int,
  criado_em            timestamptz not null default now()
);

-- Mesma tabela onde o pg_net real deposita as respostas. O reconciliador lê
-- daqui, então o teste escreve aqui para simular 2xx e 5xx.
create table net._http_response (
  id          bigint primary key,
  status_code int,
  content     text,
  error_msg   text,
  created     timestamptz not null default now()
);

-- Assinatura idêntica à do pg_net: o módulo chama com argumentos nomeados
-- (url :=, body :=, headers :=, timeout_milliseconds :=).
create function net.http_post(
  url                  text,
  body                 jsonb default '{}'::jsonb,
  params               jsonb default '{}'::jsonb,
  headers              jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds int default 5000
) returns bigint
  language plpgsql
  as $$
  declare
    v_id bigint;
  begin
    insert into net.requisicoes_stub (destino, corpo, cabecalhos, timeout_ms)
    values (url, body, headers, timeout_milliseconds)
    returning id into v_id;

    return v_id;
  end;
  $$;

create schema cron;

create table cron.job (
  jobid    bigint generated always as identity primary key,
  jobname  text unique,
  agenda   text,
  comando  text
);

create function cron.schedule(job_name text, schedule text, command text)
  returns bigint
  language plpgsql
  as $$
  declare
    v_id bigint;
  begin
    insert into cron.job (jobname, agenda, comando)
    values (job_name, schedule, command)
    returning jobid into v_id;

    return v_id;
  end;
  $$;
