-- ============================================================================
-- Kanban Clínico Rede Focoh — seed de teste
-- ----------------------------------------------------------------------------
-- Pacientes FICTÍCIOS (prefixo [TESTE]) que reproduzem os cenários de trava.
--
-- O seed não desliga triggers e não usa session_replication_role: D e E chegam
-- à coluna 6 passando pela própria trava de avanço de fase, um passo por vez.
-- Se alguma trava estiver quebrada, o seed falha — que é o comportamento
-- desejado para um seed de módulo clínico.
--
-- Como `avaliacoes_risco.nivel` é derivado por trigger, o seed (como qualquer
-- cliente) não envia `nivel`: envia só o escore.
-- ============================================================================

begin;

delete from public.pacientes
 where id in (
   '11111111-1111-4111-8111-111111111111',
   '22222222-2222-4222-8222-222222222222',
   '33333333-3333-4333-8333-333333333333',
   '44444444-4444-4444-8444-444444444444',
   '55555555-5555-4555-8555-555555555555',
   '66666666-6666-4666-8666-666666666666'
 );

-- ----------------------------------------------------------------------------
-- Admissões (toda entrada é pela coluna 1, por trigger)
-- ----------------------------------------------------------------------------
insert into public.pacientes (id, nome, programa, data_admissao) values
  ('11111111-1111-4111-8111-111111111111',
   '[TESTE] Ana Ribeiro (sem laudos)',            'Internação Integral', focoh_interno.hoje() - 40),
  ('22222222-2222-4222-8222-222222222222',
   '[TESTE] Bruno Camargo (apto a avançar)',      'Internação Integral', focoh_interno.hoje() - 20),
  ('33333333-3333-4333-8333-333333333333',
   '[TESTE] Carla Menezes (risco ativo)',         'Internação Integral', focoh_interno.hoje() - 25),
  ('44444444-4444-4444-8444-444444444444',
   '[TESTE] Diego Fontes (alta sem termo)',       'Internação Integral', focoh_interno.hoje() - 120),
  ('55555555-5555-4555-8555-555555555555',
   '[TESTE] Elisa Prado (alta com termo)',        'Internação Integral', focoh_interno.hoje() - 130),
  ('66666666-6666-4666-8666-666666666666',
   '[TESTE] Felipe Nunes (admitido hoje)',        'Internação Integral', focoh_interno.hoje());

-- ----------------------------------------------------------------------------
-- Fichas de Avaliação de Risco de Suicídio (escala 1-20, limiar padrão 15)
-- ----------------------------------------------------------------------------
insert into public.avaliacoes_risco (paciente_id, escore, avaliado_por, avaliado_em) values
  ('11111111-1111-4111-8111-111111111111',  4, null, now()),  -- baixo
  ('22222222-2222-4222-8222-222222222222',  5, null, now()),  -- baixo
  ('33333333-3333-4333-8333-333333333333', 16, null, now()),  -- >= 15 -> moderado
  ('44444444-4444-4444-8444-444444444444',  3, null, now()),  -- baixo
  ('55555555-5555-4555-8555-555555555555',  2, null, now()),  -- baixo
  ('66666666-6666-4666-8666-666666666666',  6, null, now());  -- baixo

-- ----------------------------------------------------------------------------
-- Laudos Semanais aprovados na semana vigente.
-- Ana (A) fica sem nenhum de propósito: é o cenário (a).
-- ----------------------------------------------------------------------------
insert into public.laudos_semanais (paciente_id, tipo, semana_ref, aprovado, autor, aprovado_em)
select p.id,
       t.tipo,
       focoh_interno.semana_vigente(),
       true,
       case t.tipo
         when 'clinico'     then '[TESTE] Dra. Médica Psiquiatra'
         when 'terapeutico' then '[TESTE] Psicóloga Responsável'
         when 'disciplinar' then '[TESTE] Coordenação Técnica'
       end,
       now()
  from (values
          ('22222222-2222-4222-8222-222222222222'::uuid),
          ('33333333-3333-4333-8333-333333333333'::uuid),
          ('44444444-4444-4444-8444-444444444444'::uuid),
          ('55555555-5555-4555-8555-555555555555'::uuid)
       ) as p(id)
 cross join unnest(enum_range(null::public.tipo_laudo)) as t(tipo);

-- ----------------------------------------------------------------------------
-- Diego e Elisa percorrem a jornada até a coluna 6, passando pela trava.
-- Os mesmos 3 laudos da semana vigente satisfazem cada passo.
-- ----------------------------------------------------------------------------
do $seed$
declare
  v_paciente uuid;
  v_fase     public.fase_jornada;
begin
  foreach v_paciente in array array[
    '44444444-4444-4444-8444-444444444444'::uuid,
    '55555555-5555-4555-8555-555555555555'::uuid
  ]
  loop
    foreach v_fase in array array[
      'fase1_autocritica'::public.fase_jornada,
      'fase2_disciplina',
      'fase3_empatia',
      'fase4_identidade',
      'alta_transicao'
    ]
    loop
      update public.pacientes set fase = v_fase where id = v_paciente;
    end loop;
  end loop;
end
$seed$;

-- ----------------------------------------------------------------------------
-- Termo de Saída assinado apenas para Elisa: ela é o controle positivo da
-- trava jurídica; Diego é o cenário (d).
-- ----------------------------------------------------------------------------
insert into public.termos_saida (paciente_id, tipo, pdf_url, assinado, assinado_em)
values ('55555555-5555-4555-8555-555555555555',
        'conclusiva',
        'https://exemplo.invalid/termos/teste-elisa-prado-alta-conclusiva.pdf',
        true,
        now());

-- Diego recebe o termo ainda NÃO assinado: prova que a trava olha `assinado`,
-- não a mera existência de um registro.
insert into public.termos_saida (paciente_id, tipo, pdf_url, assinado)
values ('44444444-4444-4444-8444-444444444444', 'conclusiva', null, false);

commit;
