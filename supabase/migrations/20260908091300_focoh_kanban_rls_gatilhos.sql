-- ============================================================================
-- Kanban Clínico Rede Focoh — 15/15 · RLS das tabelas dos gatilhos
-- ----------------------------------------------------------------------------
-- Mesma disciplina da migration 08: REVOKE explícito antes de conceder o
-- mínimo, nenhuma tabela aceita DELETE, e nenhuma escrita é concedida onde a
-- linha é produzida por função SECURITY DEFINER (o outbox e as auditorias não
-- devem ser forjáveis pela aplicação).
-- ============================================================================

alter table public.config_webhooks              enable row level security;
alter table public.webhooks_saida               enable row level security;
alter table public.fichas_admissao_enfermagem   enable row level security;
alter table public.protocolo_vermelho_disparos  enable row level security;
alter table public.config_cobranca_laudos       enable row level security;
alter table public.execucoes_cobranca_laudos    enable row level security;

revoke all on table
  public.config_webhooks,
  public.webhooks_saida,
  public.fichas_admissao_enfermagem,
  public.protocolo_vermelho_disparos,
  public.config_cobranca_laudos,
  public.execucoes_cobranca_laudos
from anon, authenticated;

revoke all on public.protocolo_vermelho_alertas_nao_entregues from anon, authenticated;

-- ----------------------------------------------------------------------------
-- config_webhooks — CONTÉM SEGREDO no campo `headers`
--
-- Só a Direção. Não é rigor decorativo: quem lê o cabeçalho de autenticação do
-- endpoint receptor pode forjar um alerta de Protocolo Vermelho — ou, pior,
-- redirecionar os verdadeiros trocando a URL.
-- ----------------------------------------------------------------------------
grant select, update on table public.config_webhooks to authenticated;

create policy config_webhooks_select_direcao on public.config_webhooks
  for select to authenticated
  using (focoh_interno.papel_atual() = 'diretor_geral');

create policy config_webhooks_update_direcao on public.config_webhooks
  for update to authenticated
  using (focoh_interno.papel_atual() = 'diretor_geral')
  with check (focoh_interno.papel_atual() = 'diretor_geral');

-- ----------------------------------------------------------------------------
-- webhooks_saida — o payload carrega nome de paciente e contexto operacional.
-- Leitura para gestão; escrita só pelas funções do módulo.
-- ----------------------------------------------------------------------------
grant select on table public.webhooks_saida to authenticated;

create policy webhooks_saida_select_gestao on public.webhooks_saida
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'coordenacao_tecnica', 'diretor_geral'
  ]));

-- A equipe clínica vê o estado de entrega DOS ALERTAS DE PROTOCOLO VERMELHO, e
-- só desses.
--
-- Não é conveniência: a view protocolo_vermelho_alertas_nao_entregues usa
-- `security_invoker`, então sem esta policy o LEFT JOIN em webhooks_saida
-- voltaria vazio para o médico e TODO disparo apareceria como não entregue.
-- Um painel de emergência que acusa falha onde não houve treina a equipe a
-- ignorá-lo — e aí o alerta que importa passa batido.
--
-- O payload do Protocolo Vermelho não carrega escore nem ideação (migration
-- 12), então esta visibilidade não abre dado sensível.
create policy webhooks_saida_select_pv_equipe_clinica on public.webhooks_saida
  for select to authenticated
  using (
    evento = 'protocolo_vermelho.disparo'
    and focoh_interno.e_equipe_clinica()
  );

-- ----------------------------------------------------------------------------
-- fichas_admissao_enfermagem — documento de enfermagem da Coluna 1.
-- A copa NÃO lê esta tabela: ela recebe o webhook com o que precisa.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.fichas_admissao_enfermagem to authenticated;

create policy fichas_admissao_select_clinica on public.fichas_admissao_enfermagem
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'enfermeiro_rt', 'medico_psiquiatra', 'coordenacao_tecnica', 'diretor_geral'
  ]));

create policy fichas_admissao_insert_enfermagem on public.fichas_admissao_enfermagem
  for insert to authenticated
  with check (focoh_interno.papel_atual() = any (array[
    'enfermeiro_rt', 'coordenacao_tecnica'
  ]));

create policy fichas_admissao_update_enfermagem on public.fichas_admissao_enfermagem
  for update to authenticated
  using (focoh_interno.papel_atual() = any (array['enfermeiro_rt', 'coordenacao_tecnica']))
  with check (focoh_interno.papel_atual() = any (array['enfermeiro_rt', 'coordenacao_tecnica']));

-- ----------------------------------------------------------------------------
-- protocolo_vermelho_disparos — auditoria clínica. Somente leitura, equipe
-- clínica. Escrita só pelo Gatilho 2, para que a auditoria não seja forjável.
-- ----------------------------------------------------------------------------
grant select on table public.protocolo_vermelho_disparos to authenticated;

create policy pv_disparos_select_equipe_clinica on public.protocolo_vermelho_disparos
  for select to authenticated
  using (focoh_interno.e_equipe_clinica());

-- ----------------------------------------------------------------------------
-- View de alertas não entregues — `security_invoker`, então herda as policies
-- acima. Quem não vê os disparos não vê a view.
-- ----------------------------------------------------------------------------
grant select on public.protocolo_vermelho_alertas_nao_entregues to authenticated;

-- ----------------------------------------------------------------------------
-- Configuração e execuções da cobrança de laudos
-- ----------------------------------------------------------------------------
grant select, update on table public.config_cobranca_laudos to authenticated;

create policy config_cobranca_select_equipe_clinica on public.config_cobranca_laudos
  for select to authenticated
  using (focoh_interno.e_equipe_clinica());

create policy config_cobranca_update_governanca on public.config_cobranca_laudos
  for update to authenticated
  using (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']))
  with check (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']));

grant select on table public.execucoes_cobranca_laudos to authenticated;

create policy execucoes_cobranca_select_gestao on public.execucoes_cobranca_laudos
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'coordenacao_tecnica', 'diretor_geral'
  ]));
