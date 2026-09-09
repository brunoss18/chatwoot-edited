-- ============================================================================
-- Kanban Clínico Rede Focoh — 06/08 · bloqueio de visitas nos primeiros 30 dias
-- ----------------------------------------------------------------------------
-- Regra de coluna documentada: na Fase 1 o sistema proíbe agendamento de visita
-- nos primeiros 30 dias de internação.
--
-- A trava usa a janela de 30 dias contada da admissão, não a fase atual: nos
-- primeiros 30 dias o paciente está, por definição da jornada, em Admissão ou
-- Fase 1, e amarrar na data evita que uma regressão de fase reabra a janela.
--
-- Código de erro: FCH03.
-- ============================================================================

create function focoh_interno.tg_agendamentos_visita_bloqueio_30_dias() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_liberacao date;
  begin
    if new.cancelado then
      return new;
    end if;

    select p.data_admissao + 30
      into strict v_liberacao
      from public.pacientes p
     where p.id = new.paciente_id;

    if new.data_visita < v_liberacao then
      raise exception 'Visita Bloqueada: a Fase 1 proíbe agendamento de visitas nos primeiros 30 dias de internação. Liberação a partir de %.',
        pg_catalog.to_char(v_liberacao, 'DD/MM/YYYY')
        using errcode = 'FCH03';
    end if;

    return new;
  end;
  $fn$;

create trigger agendamentos_visita_10_bloqueio_30_dias
  before insert or update of data_visita, cancelado on public.agendamentos_visita
  for each row execute function focoh_interno.tg_agendamentos_visita_bloqueio_30_dias();
