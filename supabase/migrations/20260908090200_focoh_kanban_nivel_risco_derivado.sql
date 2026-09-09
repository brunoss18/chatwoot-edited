-- ============================================================================
-- Kanban Clínico Rede Focoh — 03/08 · nível de risco derivado do escore
-- ----------------------------------------------------------------------------
-- Por que derivar em vez de aceitar `nivel` do cliente: se escore e nível
-- fossem campos independentes, um lançamento com escore 18 e nível "baixo"
-- passaria a trava de fase e não dispararia o Protocolo Vermelho. O escore é o
-- dado; o nível é consequência dos limiares configurados.
-- ============================================================================

create function focoh_interno.tg_avaliacoes_risco_derivar_nivel() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    v_limiar_moderado int;
    v_limiar_alto     int;
  begin
    -- Config é registro obrigatório de produção: ausência é bug de deploy,
    -- e falhar aqui é melhor que classificar risco com limiar inventado.
    select c.limiar_moderado, c.limiar_alto
      into strict v_limiar_moderado, v_limiar_alto
      from public.config_protocolo_vermelho c
     where c.id = 1;

    new.nivel := case
      when v_limiar_alto is not null and new.escore >= v_limiar_alto then 'alto'
      when new.escore >= v_limiar_moderado                           then 'moderado'
      else 'baixo'
    end::public.nivel_risco;

    return new;
  end;
  $fn$;

comment on function focoh_interno.tg_avaliacoes_risco_derivar_nivel() is
  'Deriva avaliacoes_risco.nivel do escore usando os limiares editáveis de config_protocolo_vermelho.';

create trigger avaliacoes_risco_10_derivar_nivel
  before insert or update of escore on public.avaliacoes_risco
  for each row execute function focoh_interno.tg_avaliacoes_risco_derivar_nivel();

-- ----------------------------------------------------------------------------
-- Avaliação vigente única: lançar uma nova ficha desativa a anterior.
-- Sem isto o índice único parcial rejeitaria o novo lançamento, ou seja: uma
-- reavaliação de risco falharia justamente quando o quadro do paciente mudou.
--
-- Tem de ser BEFORE INSERT: `avaliacoes_risco_uma_ativa_por_paciente_idx` é um
-- índice único não postergável, avaliado durante o próprio INSERT. Um trigger
-- AFTER INSERT nunca chegaria a rodar.
-- ----------------------------------------------------------------------------
create function focoh_interno.tg_avaliacoes_risco_desativar_anteriores() returns trigger
  language plpgsql security definer set search_path = ''
  as $fn$
  begin
    if new.ativo then
      update public.avaliacoes_risco
         set ativo = false
       where paciente_id = new.paciente_id
         and ativo;
    end if;
    return new;
  end;
  $fn$;

comment on function focoh_interno.tg_avaliacoes_risco_desativar_anteriores() is
  'Encerra a ficha de risco vigente quando uma nova é lançada. Sem recursão: o UPDATE não toca `escore`, e este trigger é apenas de INSERT.';

create trigger avaliacoes_risco_20_desativar_anteriores
  before insert on public.avaliacoes_risco
  for each row execute function focoh_interno.tg_avaliacoes_risco_desativar_anteriores();

-- ----------------------------------------------------------------------------
-- Leitura do nível vigente para uso interno das travas e do board.
--
-- SECURITY DEFINER porque quem move o cartão pode ser a recepção, que não tem
-- (e não deve ter) SELECT em avaliacoes_risco. EXECUTE fica só com o owner:
-- as funções que a chamam também são SECURITY DEFINER.
-- ----------------------------------------------------------------------------
create function focoh_interno.nivel_risco_vigente(p_paciente_id uuid)
  returns public.nivel_risco
  language sql stable security definer set search_path = ''
  as $fn$
    select a.nivel
      from public.avaliacoes_risco a
     where a.paciente_id = p_paciente_id
       and a.ativo
     order by a.avaliado_em desc
     limit 1
  $fn$;

revoke all on function focoh_interno.nivel_risco_vigente(uuid) from public;

comment on function focoh_interno.nivel_risco_vigente(uuid) is
  'Nível de risco vigente do paciente, ou NULL se nunca avaliado. Devolve o nível, nunca o escore. EXECUTE revogado de PUBLIC: só o owner (e as funções SECURITY DEFINER dele) chamam.';
