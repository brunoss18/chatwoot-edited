-- ============================================================================
-- Kanban Clínico Rede Focoh — 05/08 · TRAVA DE SAÍDA JURÍDICA (coluna 6)
-- ----------------------------------------------------------------------------
-- Gatilho 4 dos Protocolos Automáticos de Segurança: o backend impede o
-- arquivamento do paciente enquanto não houver upload do PDF assinado do termo
-- de saída correspondente (Alta Conclusiva / Administrativa / a Pedido / a
-- Pedido em Involuntariedade por Familiar).
--
-- Leitura adotada de "cartão arquivado ao entrar na coluna 6": entrar na coluna
-- 6 e arquivar são dois atos. Entrar na coluna 6 passa pela trava de avanço de
-- fase (migration 04); arquivar é o desligamento e passa por esta trava. Se
-- entrar na coluna já arquivasse, o paciente em transição AMANDA sairia do
-- board antes do pós-alta — e a documentação coloca o pós-alta dentro da
-- coluna 6.
--
-- Código de erro: FCH02.
-- ============================================================================

create function focoh_interno.tg_pacientes_trava_saida_juridica() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  begin
    if new.arquivado is not true or old.arquivado is true then
      return new;
    end if;

    if new.fase <> 'alta_transicao' then
      raise exception 'Arquivamento Bloqueado: o paciente só pode ser arquivado na coluna "Alta Hospitalar e Transição AMANDA".'
        using errcode = 'FCH02';
    end if;

    -- `assinado` já implica PDF anexado pela constraint
    -- termos_saida_assinado_exige_pdf, então basta checar o flag.
    if not exists (
      select 1
        from public.termos_saida t
       where t.paciente_id = new.id
         and t.assinado
    ) then
      raise warning 'Kanban Focoh: arquivamento bloqueado paciente=% papel=% motivo=termo_saida_ausente',
        new.id, focoh_interno.papel_atual();

      raise exception '%', focoh_interno.msg_arquivamento_bloqueado()
        using errcode = 'FCH02',
              detail  = 'termo_saida_assinado=nao';
    end if;

    new.arquivado_em := coalesce(new.arquivado_em, pg_catalog.now());
    return new;
  end;
  $fn$;

comment on function focoh_interno.tg_pacientes_trava_saida_juridica() is
  'Trava de saída jurídica: arquivar exige coluna 6 e Termo de Saída assinado com PDF.';

-- Nomes numerados garantem a ordem de disparo (o Postgres ordena triggers de
-- mesmo evento por nome): 00 admissão, 10 avanço de fase, 20 saída jurídica,
-- 90 timestamp.
create trigger pacientes_20_trava_saida_juridica
  before update on public.pacientes
  for each row execute function focoh_interno.tg_pacientes_trava_saida_juridica();
