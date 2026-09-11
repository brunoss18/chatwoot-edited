-- ============================================================================
-- Prelúdio APENAS para execução local/offline das migrations (harness PGlite).
-- ----------------------------------------------------------------------------
-- Recria o mínimo que o Supabase já fornece em qualquer projeto: os roles
-- anon/authenticated/service_role, o schema `auth` com `auth.jwt()`/`auth.uid()`
-- e os default privileges amplos em `public`.
--
-- NÃO é uma migration e NÃO deve ser aplicado no projeto Supabase.
-- ============================================================================

create role anon         nologin noinherit;
create role authenticated nologin noinherit;
create role service_role  nologin noinherit bypassrls;

create schema if not exists auth;


create function auth.jwt() returns jsonb
  language sql stable
  as $$
    select coalesce(
      nullif(current_setting('request.jwt.claims', true), '')::jsonb,
      '{}'::jsonb)
  $$;

create function auth.uid() returns uuid
  language sql stable
  as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth   to anon, authenticated, service_role;

-- O Supabase concede privilégios amplos por default privileges, inclusive a
-- `anon`. Reproduzir isso aqui é o que torna o REVOKE explícito da migration
-- 08 um comportamento efetivamente testado, e não decorativo.
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
-- FUNÇÕES também, e esta linha é dívida paga: sem ela o harness não reproduzia
-- o Supabase real, onde toda função criada em `public` nasce com EXECUTE
-- concedido nominalmente a `anon`. A ausência disso deixou passar um
-- /rest/v1/rpc/cards_do_quadro anônimo respondendo 200 em produção (corrigido
-- pela migration 16).
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
