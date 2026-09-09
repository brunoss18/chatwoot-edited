-- ============================================================================
-- Kanban Clínico Rede Focoh — 14/15 · agendamentos (pg_cron)
-- ----------------------------------------------------------------------------
-- Três rotinas agendadas. Se o pg_cron não estiver habilitado no projeto, esta
-- migration FALHA — de propósito: um Protocolo Vermelho cujo reconciliador
-- nunca roda é um alerta que ninguém sabe que não chegou.
--
-- Os horários da cobrança de laudos NÃO estão aqui: estão em
-- config_cobranca_laudos. A varredura de 15 minutos só pergunta "é hora?".
-- ============================================================================


-- Rede de segurança do outbox: pega o que ficou pendente (o Protocolo Vermelho
-- e a Copa despacham na hora, então aqui cai o reenfileirado por falha).
select cron.schedule(
  'focoh-despachar-webhooks',
  '* * * * *',
  $cron$ select focoh_interno.despachar_webhooks_pendentes(); $cron$
);

-- Fecha a auditoria de ENTREGA: confirma os 2xx, reenfileira o resto e marca
-- como falha o que não dá mais para comprovar.
select cron.schedule(
  'focoh-reconciliar-webhooks',
  '* * * * *',
  $cron$ select focoh_interno.reconciliar_webhooks(); $cron$
);

-- Cobrança de laudos: a função decide a janela a partir da config.
select cron.schedule(
  'focoh-cobranca-laudos',
  '*/15 * * * *',
  $cron$ select focoh_interno.processar_cobranca_laudos(); $cron$
);
