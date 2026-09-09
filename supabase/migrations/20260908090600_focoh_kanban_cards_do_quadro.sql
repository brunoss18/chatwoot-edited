-- ============================================================================
-- Kanban Clínico Rede Focoh — 07/08 · cards_do_quadro()
-- ----------------------------------------------------------------------------
-- Esta é a ÚNICA porta de leitura do board. O frontend chama
-- `supabase.rpc('cards_do_quadro')` e nunca faz select em `avaliacoes_risco`
-- nem em `laudos_semanais`.
--
-- O que ela devolve sobre risco:
--   protocolo_vermelho_ativo  boolean  -> vira "🔴 Protocolo Vermelho ativo"
--   nivel_pendencia           enum     -> 'pendencia_clinica' cobre moderado E alto
--
-- O que ela NUNCA devolve: escore, nível de risco textual, ideacao_detalhes,
-- data da avaliação. Um cartão visível à recepção não permite inferir gravidade.
--
-- SECURITY DEFINER dá acesso à tabela sensível, portanto a autorização é feita
-- DENTRO da função (`e_staff()`) e o EXECUTE é revogado de PUBLIC/anon.
-- ============================================================================

create function public.cards_do_quadro(p_incluir_arquivados boolean default false)
  returns table (
    id                        uuid,
    nome                      text,
    fase                      public.fase_jornada,
    programa                  text,
    data_admissao             date,
    dias_internado            int,
    tem_laudo                 boolean,
    tem_3_laudos              boolean,
    laudos_pendentes          public.tipo_laudo[],
    nivel_pendencia           public.nivel_pendencia_card,
    protocolo_vermelho_ativo  boolean,
    pode_avancar              boolean,
    arquivado                 boolean
  )
  language sql stable security definer set search_path = ''
  as $fn$
    select
      p.id,
      p.nome,
      p.fase,
      p.programa,
      p.data_admissao,
      (focoh_interno.hoje() - p.data_admissao)::int                     as dias_internado,
      l.aprovados > 0                                                   as tem_laudo,
      l.aprovados = 3                                                   as tem_3_laudos,
      l.pendentes                                                       as laudos_pendentes,
      case
        when r.nivel is null    then 'sem_avaliacao_risco'
        when r.nivel <> 'baixo' then 'pendencia_clinica'
        when l.aprovados < 3    then 'laudos_pendentes'
        else                         'nenhuma'
      end::public.nivel_pendencia_card                                  as nivel_pendencia,
      coalesce(r.nivel <> 'baixo', false)                               as protocolo_vermelho_ativo,
      (l.aprovados = 3
        and r.nivel = 'baixo'
        and not p.arquivado
        and p.fase <> 'alta_transicao')                                 as pode_avancar,
      p.arquivado
    from public.pacientes p
    cross join lateral (
      select
        pg_catalog.count(*) filter (where y.aprovado)::int              as aprovados,
        coalesce(
          pg_catalog.array_agg(y.tipo_laudo order by y.tipo_laudo)
            filter (where not y.aprovado),
          array[]::public.tipo_laudo[])                                 as pendentes
      from (
        select u.tipo_laudo,
               exists (
                 select 1
                   from public.laudos_semanais lc
                  where lc.paciente_id = p.id
                    and lc.tipo        = u.tipo_laudo
                    and lc.semana_ref  = focoh_interno.semana_vigente()
                    and lc.aprovado
               ) as aprovado
          from pg_catalog.unnest(pg_catalog.enum_range(null::public.tipo_laudo))
               as u(tipo_laudo)
      ) y
    ) l
    left join lateral (
      select a.nivel
        from public.avaliacoes_risco a
       where a.paciente_id = p.id
         and a.ativo
       order by a.avaliado_em desc
       limit 1
    ) r on true
    where focoh_interno.e_staff()
      and (p_incluir_arquivados or not p.arquivado)
    order by focoh_interno.fase_ordem(p.fase), p.data_admissao, p.nome
  $fn$;

comment on function public.cards_do_quadro(boolean) is
  'Fonte de leitura do board Kanban. Devolve flags clínicos derivados sem expor escore de risco, nível textual ou detalhes de ideação. Autoriza internamente por papel (app_metadata.role).';

revoke all on function public.cards_do_quadro(boolean) from public;
grant execute on function public.cards_do_quadro(boolean) to authenticated;
