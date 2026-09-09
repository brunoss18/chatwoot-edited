-- ============================================================================
-- Kanban Clínico Rede Focoh — 01/15 · extensões exigidas
-- ----------------------------------------------------------------------------
-- Isoladas neste arquivo por dois motivos:
--
-- 1. Falha aqui é diagnóstico claro. Se o projeto Supabase não tem pg_net ou
--    pg_cron habilitados, a instalação para na primeira migration, com a
--    mensagem apontando a extensão — e não no meio do módulo, num
--    `net.http_post` que não existe.
--
-- 2. O harness offline (supabase/tests) não consegue instalar extensões nativas
--    no Postgres em WASM, então ele pula EXCLUSIVAMENTE este arquivo e injeta
--    stubs de `net` e `cron` no lugar. Mantendo os `create extension` só aqui,
--    nenhuma outra migration precisa ser adaptada para ser testável.
--
-- pg_net  — POST HTTP assíncrono a partir do banco (transporte dos webhooks).
-- pg_cron — agendador do reconciliador de entrega e da cobrança de laudos.
--
-- Sem pg_cron não há reconciliação de entrega, e um Protocolo Vermelho que
-- falhou seria um alerta que ninguém sabe que não chegou. É por isso que a
-- ausência da extensão precisa estourar, não degradar.
-- ============================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;
