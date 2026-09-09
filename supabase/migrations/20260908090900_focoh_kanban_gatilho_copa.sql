-- ============================================================================
-- Kanban Clínico Rede Focoh — 11/15 · Gatilho 1: Copa (restrição alimentar)
-- ----------------------------------------------------------------------------
-- Quando: ingestão da ficha de admissão de enfermagem (Coluna 1), com
-- `restricao_alimentar` preenchido com algo diferente de "Não possui".
--
-- Ação: webhook que gera alerta em destaque nas telas da copa/cozinha/
-- hotelaria, sinalizando que refeição comum não deve ser liberada para a suíte
-- do paciente.
--
-- Escopo do payload: é alerta OPERACIONAL. Vai o nome, a suíte e a restrição —
-- nada de diagnóstico, escore ou fase da jornada. A cozinha precisa saber o que
-- não servir e onde, não o quadro clínico de quem vai comer.
-- ============================================================================

create function focoh_interno.sem_restricao_alimentar() returns text
  language sql immutable parallel safe set search_path = ''
  as $fn$ select 'Não possui'::text $fn$;

comment on function focoh_interno.sem_restricao_alimentar() is
  'Sentinela documentada do campo restricao_alimentar. Uma definição só, para que o gatilho da Copa e o formulário não divirjam.';

create table public.fichas_admissao_enfermagem (
  id                   uuid primary key default gen_random_uuid(),
  paciente_id          uuid not null references public.pacientes (id) on delete cascade,
  restricao_alimentar  text not null default focoh_interno.sem_restricao_alimentar(),
  suite                text,
  preenchida_por       uuid,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),

  constraint fichas_admissao_restricao_preenchida
    check (length(btrim(restricao_alimentar)) > 0)
);

comment on table public.fichas_admissao_enfermagem is
  'Ficha de admissão de enfermagem (Coluna 1). Alimenta o Gatilho 1 (Copa).';
comment on column public.fichas_admissao_enfermagem.restricao_alimentar is
  'Alergia ou restrição alimentar. "Não possui" é o valor neutro; qualquer outro texto dispara o alerta da copa.';
comment on column public.fichas_admissao_enfermagem.preenchida_por is
  'Claim `sub` do JWT (UUIDv5 do usuário Chatwoot) de quem preencheu a ficha.';

create trigger fichas_admissao_enfermagem_90_touch
  before update on public.fichas_admissao_enfermagem
  for each row execute function focoh_interno.tg_touch_atualizado_em();

create index fichas_admissao_enfermagem_paciente_idx
  on public.fichas_admissao_enfermagem (paciente_id, criado_em desc);

-- ----------------------------------------------------------------------------
-- O gatilho
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_fichas_admissao_alerta_copa() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_paciente public.pacientes;
    v_saida_id bigint;
  begin
    if pg_catalog.btrim(new.restricao_alimentar)
       = focoh_interno.sem_restricao_alimentar() then
      return null;
    end if;

    select * into v_paciente from public.pacientes where id = new.paciente_id;

    v_saida_id := focoh_interno.enfileirar_webhook(
      'copa.restricao_alimentar',
      new.paciente_id,
      pg_catalog.jsonb_build_object(
        'evento', 'copa.restricao_alimentar',
        'paciente_id', new.paciente_id,
        'paciente_nome', v_paciente.nome,
        'suite', new.suite,
        'restricao_alimentar', new.restricao_alimentar,
        'orientacao', 'Refeição comum NÃO deve ser liberada para esta suíte.',
        'registrado_em', new.criado_em
      )
    );

    -- Refeição pode estar sendo montada agora: despacha na hora em vez de
    -- esperar a varredura agendada.
    perform focoh_interno.despachar_webhook(v_saida_id);

    return null;
  end;
  $fn$;

-- AFTER: só alerta a copa sobre ficha que de fato foi gravada.
create trigger fichas_admissao_enfermagem_10_alerta_copa
  after insert or update of restricao_alimentar
  on public.fichas_admissao_enfermagem
  for each row execute function focoh_interno.tg_fichas_admissao_alerta_copa();
