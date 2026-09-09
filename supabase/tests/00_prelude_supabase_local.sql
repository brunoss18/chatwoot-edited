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

-- No Supabase real esta tabela tem muitas outras colunas; o módulo só depende
-- do `id` (chaves estrangeiras de autoria).
create table auth.users (
  id    uuid primary key,
  email text
);

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
