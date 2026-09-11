-- ============================================================================
-- Kanban Clínico Rede Focoh — 16/16 · fecha o EXECUTE do papel `anon`
-- ----------------------------------------------------------------------------
-- Descoberto ao aplicar as migrations num projeto Supabase real, e invisível no
-- harness até agora: o Supabase declara
--
--   alter default privileges in schema public grant all on functions
--     to postgres, anon, authenticated, service_role;
--
-- Então toda função criada em `public` nasce com EXECUTE concedido a `anon`
-- NOMINALMENTE. O `revoke all ... from public` das migrations 08 e 09 remove a
-- concessão do pseudo-papel PUBLIC e não toca numa concessão nominal.
--
-- Efeito medido antes deste arquivo: um POST anônimo em
-- /rest/v1/rpc/cards_do_quadro respondia 200. Não vazou nada, porque a função
-- autoriza internamente por `focoh_interno.e_staff()` e devolvia lista vazia.
-- A defesa em profundidade funcionou; a primeira camada é que não estava lá.
--
-- CUIDADO ao editar: as funções de `focoh_interno` nunca receberam EXECUTE
-- nominal para `authenticated` — elas dependiam da concessão default a PUBLIC,
-- e é isso que as policies de RLS, os DEFAULT de coluna e o guarda da UPCI
-- chamam. Revogar de PUBLIC sem reconceder a `authenticated` derruba o módulo
-- inteiro com "permission denied for function papel_atual".
-- ============================================================================

-- ----------------------------------------------------------------------------
-- public.cards_do_quadro — a porta do board
-- ----------------------------------------------------------------------------
revoke execute on function public.cards_do_quadro(boolean) from anon;

-- ----------------------------------------------------------------------------
-- focoh_interno — fecha PUBLIC e anon, devolve o necessário a authenticated
-- ----------------------------------------------------------------------------
revoke execute on all functions in schema focoh_interno from public;
revoke execute on all functions in schema focoh_interno from anon;

-- `authenticated` precisa dos helpers: as policies avaliam com os privilégios
-- de quem consulta, e os DEFAULT de coluna (`focoh_interno.hoje()`,
-- `sem_restricao_alimentar()`) são avaliados com os de quem insere.
grant execute on all functions in schema focoh_interno to authenticated;

-- ----------------------------------------------------------------------------
-- E então fecha de novo, nominalmente, o que não pode ser chamado por ninguém
-- de fora: estas ou devolvem risco, ou disparam alerta, ou expõem pendências.
-- Todas continuam funcionando onde importa, porque quem as usa são as funções
-- SECURITY DEFINER e os triggers, que rodam como o owner.
-- ----------------------------------------------------------------------------
revoke execute on function focoh_interno.nivel_risco_vigente(uuid)
  from authenticated, anon, public;

revoke execute on function focoh_interno.enfileirar_webhook(public.evento_webhook, uuid, jsonb)
  from authenticated, anon, public;
revoke execute on function focoh_interno.despachar_webhook(bigint)
  from authenticated, anon, public;
revoke execute on function focoh_interno.despachar_webhooks_pendentes(int)
  from authenticated, anon, public;
revoke execute on function focoh_interno.reconciliar_webhooks()
  from authenticated, anon, public;

revoke execute on function focoh_interno.laudos_pendentes_da_semana()
  from authenticated, anon, public;
revoke execute on function focoh_interno.processar_cobranca_laudos()
  from authenticated, anon, public;

-- Fecha a porta para o futuro: função nova neste schema não nasce concedida a
-- anon. O default de `public` não é alterado de propósito — aquele schema é
-- compartilhado com outros módulos no mesmo banco.
alter default privileges in schema focoh_interno revoke execute on functions from anon;
