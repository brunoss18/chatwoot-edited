-- ============================================================================
-- Kanban Clínico Rede Focoh — 09/15 · RLS e privilégios
-- ----------------------------------------------------------------------------
-- Modelo de acesso: todo usuário logado é o role Postgres `authenticated`; o
-- papel clínico vem do JWT em `app_metadata.role`. Portanto o privilégio
-- (GRANT) é igual para todos e a separação real acontece nas policies.
--
-- O Supabase concede privilégios amplos em `public` por default privileges,
-- inclusive a `anon`. Por isso cada tabela abaixo começa com REVOKE explícito
-- antes de conceder o mínimo necessário: nenhuma tabela deste módulo é
-- acessível sem sessão autenticada, e nenhuma aceita DELETE.
--
-- Não usamos FORCE ROW LEVEL SECURITY: o owner precisa continuar isento para
-- que `cards_do_quadro()` (SECURITY DEFINER) consiga derivar os flags a partir
-- da tabela sensível.
-- ============================================================================

alter table public.pacientes                  enable row level security;
alter table public.laudos_semanais            enable row level security;
alter table public.avaliacoes_risco           enable row level security;
alter table public.termos_saida               enable row level security;
alter table public.agendamentos_visita        enable row level security;
alter table public.config_protocolo_vermelho  enable row level security;
alter table public.auditoria_transicoes_fase  enable row level security;

revoke all on table
  public.pacientes,
  public.laudos_semanais,
  public.avaliacoes_risco,
  public.termos_saida,
  public.agendamentos_visita,
  public.config_protocolo_vermelho,
  public.auditoria_transicoes_fase
from anon, authenticated;

-- ----------------------------------------------------------------------------
-- pacientes — o board. Recepção/atendimento vê e move cartões; as travas
-- clínicas continuam sendo aplicadas pelos triggers, não pela RLS.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.pacientes to authenticated;

create policy pacientes_select_staff on public.pacientes
  for select to authenticated
  using (focoh_interno.e_staff());

create policy pacientes_insert_admissao on public.pacientes
  for insert to authenticated
  with check (focoh_interno.papel_atual() = any (array[
    'recepcao', 'enfermeiro_rt', 'coordenacao_tecnica'
  ]));

create policy pacientes_update_staff on public.pacientes
  for update to authenticated
  using (focoh_interno.e_staff())
  with check (focoh_interno.e_staff());

-- ----------------------------------------------------------------------------
-- laudos_semanais — a recepção NÃO lê laudos. Ela vê `tem_3_laudos` e
-- `laudos_pendentes` via cards_do_quadro(), que é o suficiente para cobrança.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.laudos_semanais to authenticated;

create policy laudos_select_equipe_clinica on public.laudos_semanais
  for select to authenticated
  using (focoh_interno.e_equipe_clinica());

-- Cada laudo é assinado por quem a regra Anexo Fases designa: Clínico pelo
-- médico psiquiatra, Terapêutico pelo psicólogo, Disciplinar pela coordenação.
create policy laudos_insert_aprovador on public.laudos_semanais
  for insert to authenticated
  with check (
    focoh_interno.papel_atual() = any (focoh_interno.papeis_aprovadores_laudo(tipo))
  );

create policy laudos_update_aprovador on public.laudos_semanais
  for update to authenticated
  using (focoh_interno.papel_atual() = any (focoh_interno.papeis_aprovadores_laudo(tipo)))
  with check (focoh_interno.papel_atual() = any (focoh_interno.papeis_aprovadores_laudo(tipo)));

-- ----------------------------------------------------------------------------
-- avaliacoes_risco — TABELA SENSÍVEL
--
-- Nenhuma policy contempla 'recepcao' ou 'gerente_familias': para eles a
-- tabela simplesmente não tem linhas. É este isolamento que permite dizer que
-- o escore não vaza pelo board, porque o board lê só a SECURITY DEFINER.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.avaliacoes_risco to authenticated;

create policy avaliacoes_risco_select_equipe_clinica on public.avaliacoes_risco
  for select to authenticated
  using (focoh_interno.e_equipe_clinica());

-- Quem lança a Ficha de Avaliação de Risco de Suicídio.
create policy avaliacoes_risco_insert_avaliadores on public.avaliacoes_risco
  for insert to authenticated
  with check (focoh_interno.papel_atual() = any (array[
    'medico_psiquiatra', 'psicologo', 'enfermeiro_rt'
  ]));

-- Reavaliação (encerrar a ficha vigente) fica com a equipe clínica.
create policy avaliacoes_risco_update_equipe_clinica on public.avaliacoes_risco
  for update to authenticated
  using (focoh_interno.e_equipe_clinica())
  with check (focoh_interno.e_equipe_clinica());

-- ----------------------------------------------------------------------------
-- termos_saida — documentos jurídicos com dado de paciente.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.termos_saida to authenticated;

create policy termos_saida_select_gestao on public.termos_saida
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'coordenacao_tecnica', 'diretor_geral', 'medico_psiquiatra'
  ]));

create policy termos_saida_insert_gestao on public.termos_saida
  for insert to authenticated
  with check (focoh_interno.papel_atual() = any (array[
    'coordenacao_tecnica', 'diretor_geral'
  ]));

create policy termos_saida_update_gestao on public.termos_saida
  for update to authenticated
  using (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']))
  with check (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']));

-- ----------------------------------------------------------------------------
-- agendamentos_visita — operação de recepção e relacionamento com famílias.
-- ----------------------------------------------------------------------------
grant select, insert, update on table public.agendamentos_visita to authenticated;

create policy agendamentos_visita_select_operacao on public.agendamentos_visita
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'recepcao', 'gerente_familias', 'coordenacao_tecnica', 'diretor_geral'
  ]));

create policy agendamentos_visita_insert_operacao on public.agendamentos_visita
  for insert to authenticated
  with check (focoh_interno.papel_atual() = any (array[
    'recepcao', 'gerente_familias', 'coordenacao_tecnica'
  ]));

create policy agendamentos_visita_update_operacao on public.agendamentos_visita
  for update to authenticated
  using (focoh_interno.papel_atual() = any (array[
    'recepcao', 'gerente_familias', 'coordenacao_tecnica'
  ]))
  with check (focoh_interno.papel_atual() = any (array[
    'recepcao', 'gerente_familias', 'coordenacao_tecnica'
  ]));

-- ----------------------------------------------------------------------------
-- config_protocolo_vermelho — limiar e destinatários do Protocolo Vermelho.
-- Alterar aqui é ato de governança clínica: só Coordenação Técnica e Direção.
-- ----------------------------------------------------------------------------
grant select, update on table public.config_protocolo_vermelho to authenticated;

create policy config_pv_select_equipe_clinica on public.config_protocolo_vermelho
  for select to authenticated
  using (focoh_interno.e_equipe_clinica());

create policy config_pv_update_governanca on public.config_protocolo_vermelho
  for update to authenticated
  using (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']))
  with check (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']));

-- ----------------------------------------------------------------------------
-- auditoria_transicoes_fase — somente leitura para a gestão. A escrita é feita
-- pelo trigger SECURITY DEFINER (owner), que é isento de RLS; `authenticated`
-- não recebe INSERT para que a auditoria não seja forjável pela aplicação.
-- ----------------------------------------------------------------------------
grant select on table public.auditoria_transicoes_fase to authenticated;

create policy auditoria_transicoes_select_gestao on public.auditoria_transicoes_fase
  for select to authenticated
  using (focoh_interno.papel_atual() = any (array['coordenacao_tecnica', 'diretor_geral']));
