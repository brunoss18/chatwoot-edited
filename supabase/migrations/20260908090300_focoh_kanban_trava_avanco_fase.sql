-- ============================================================================
-- Kanban Clínico Rede Focoh — 05/15 · TRAVA DE AVANÇO DE FASE (Anexo Fases)
-- ----------------------------------------------------------------------------
-- REGRA INSTITUCIONAL:
--   "A progressão não ocorre por tempo, pressão ou percepção subjetiva —
--    só quando todos os critérios mínimos estão atendidos."
--
-- Mover um cartão para a coluna seguinte só é permitido quando, para aquele
-- paciente e na SEMANA VIGENTE, TODAS as condições são verdadeiras:
--   1. Laudo Clínico semanal aprovado (médico psiquiatra)
--   2. Laudo Terapêutico semanal aprovado (psicólogo)
--   3. Laudo Disciplinar semanal aprovado (coordenação/manejo)
--   4. Nível de risco = Baixo — risco Moderado ou Alto barra o avanço mesmo
--      com os 3 laudos aprovados.
--
-- Paciente sem nenhuma Ficha de Avaliação de Risco também é barrado: "sem
-- avaliação" não é "risco baixo". A escala de risco é tarefa da própria
-- coluna 1 (Admissão e Triagem Inicial), então avançar sem ela é avançar sem
-- ter cumprido a triagem.
--
-- Códigos de erro (lidos pelo frontend em error.code):
--   FCH01 avanço bloqueado · FCH04 paciente arquivado
--   FCH05 regressão exige equipe clínica · FCH06 jornada é sequencial
--   FCH07 admissão fora da coluna 1
-- ============================================================================

create function focoh_interno.tg_pacientes_trava_avanco_fase() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_semana      date := focoh_interno.semana_vigente();
    v_ordem_atual int  := focoh_interno.fase_ordem(old.fase);
    v_ordem_nova  int  := focoh_interno.fase_ordem(new.fase);
    v_pendentes   public.tipo_laudo[];
    v_nivel       public.nivel_risco;
    v_risco_texto text;
  begin
    if new.fase = old.fase then
      return new;
    end if;

    if old.arquivado then
      raise exception 'Paciente arquivado: reabra o caso antes de alterar a fase.'
        using errcode = 'FCH04';
    end if;

    -- Regressão de fase é decisão clínica documentada, não correção de arraste.
    -- Não passa pelos critérios de avanço, mas exige papel da equipe clínica.
    if v_ordem_nova < v_ordem_atual then
      if not focoh_interno.e_equipe_clinica() then
        raise exception 'Regressão de fase é decisão clínica e exige papel da equipe clínica.'
          using errcode = 'FCH05';
      end if;

      insert into public.auditoria_transicoes_fase
        (paciente_id, fase_origem, fase_destino, regressao, papel_ator, ator_user_id)
      values
        (new.id, old.fase, new.fase, true, focoh_interno.papel_atual(), auth.uid());

      return new;
    end if;

    -- A jornada é sequencial: não existe pular etapa clínica.
    if v_ordem_nova > v_ordem_atual + 1 then
      raise exception 'A jornada do paciente é sequencial: avance uma coluna por vez.'
        using errcode = 'FCH06';
    end if;

    -- Condições 1 a 3: os 3 Laudos Semanais aprovados na semana vigente.
    -- Alias explícito em `u(tipo_laudo)`: com a coluna chamada `tipo`, o
    -- `l.tipo = tipo` do EXISTS resolveria para `l.tipo = l.tipo` (escopo
    -- interno vence) e a checagem passaria sempre.
    select coalesce(
             pg_catalog.array_agg(x.tipo_laudo order by x.tipo_laudo)
               filter (where not x.aprovado),
             array[]::public.tipo_laudo[])
      into v_pendentes
      from (
        select u.tipo_laudo,
               exists (
                 select 1
                   from public.laudos_semanais l
                  where l.paciente_id = new.id
                    and l.tipo        = u.tipo_laudo
                    and l.semana_ref  = v_semana
                    and l.aprovado
               ) as aprovado
          from pg_catalog.unnest(pg_catalog.enum_range(null::public.tipo_laudo))
               as u(tipo_laudo)
      ) x;

    -- Condição 4: ausência de risco ativo.
    v_nivel := focoh_interno.nivel_risco_vigente(new.id);

    if coalesce(pg_catalog.array_length(v_pendentes, 1), 0) > 0
       or v_nivel is distinct from 'baixo' then

      -- DETAIL é devolvido ao cliente, então descreve o risco como estado
      -- ('sim'/'nao'/'sem_avaliacao'), nunca como escore ou nível.
      v_risco_texto := case
        when v_nivel is null      then 'sem_avaliacao'
        when v_nivel = 'baixo'    then 'nao'
        else                           'sim'
      end;

      raise warning 'Kanban Focoh: avanço bloqueado paciente=% origem=% destino=% laudos_pendentes=% risco_ativo=% papel=%',
        new.id, old.fase, new.fase, v_pendentes, v_risco_texto, focoh_interno.papel_atual();

      raise exception '%', focoh_interno.msg_avanco_bloqueado()
        using errcode = 'FCH01',
              detail  = pg_catalog.format(
                          'laudos_pendentes=%s; risco_ativo=%s; semana_ref=%s',
                          v_pendentes, v_risco_texto, v_semana);
    end if;

    insert into public.auditoria_transicoes_fase
      (paciente_id, fase_origem, fase_destino, regressao, papel_ator, ator_user_id)
    values
      (new.id, old.fase, new.fase, false, focoh_interno.papel_atual(), auth.uid());

    return new;
  end;
  $fn$;

comment on function focoh_interno.tg_pacientes_trava_avanco_fase() is
  'Trava de avanço de fase (Anexo Fases): 3 laudos semanais aprovados na semana vigente + risco Baixo. SECURITY DEFINER porque precisa ler avaliacoes_risco, que a recepção não acessa.';

-- BEFORE UPDATE sem lista de colunas: qualquer caminho que mude `fase` passa
-- por aqui, inclusive UPDATE que altere outras colunas junto.
create trigger pacientes_10_trava_avanco_fase
  before update on public.pacientes
  for each row execute function focoh_interno.tg_pacientes_trava_avanco_fase();

-- ----------------------------------------------------------------------------
-- Admissão sempre pela coluna 1
--
-- Sem isto a trava de avanço seria contornável por INSERT: bastaria criar o
-- paciente já em 'fase4_identidade' e nenhum laudo teria sido exigido.
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_pacientes_admissao_na_coluna_1() returns trigger
  language plpgsql set search_path = ''
  as $fn$
  begin
    if new.fase <> 'admissao_triagem' then
      raise exception 'Todo paciente entra na jornada pela coluna "Admissão e Triagem Inicial".'
        using errcode = 'FCH07';
    end if;

    if new.arquivado then
      raise exception 'Paciente não pode ser criado já arquivado.'
        using errcode = 'FCH07';
    end if;

    return new;
  end;
  $fn$;

create trigger pacientes_00_admissao_na_coluna_1
  before insert on public.pacientes
  for each row execute function focoh_interno.tg_pacientes_admissao_na_coluna_1();
