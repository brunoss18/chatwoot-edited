-- ============================================================================
-- Kanban Clínico Rede Focoh — 17/17 · corrige o SENTIDO da escala de risco
-- ----------------------------------------------------------------------------
-- O briefing original dizia "limiar padrão documentado = 15 pontos (escala
-- 1–20)" e "quando a pontuação ATINGE o limiar", o que levou a um `>=`. O
-- documento clínico definitivo (Avaliação de risco de suicídio, via Mapa
-- Objetivo) diz o contrário: a escala é INVERTIDA.
--
--     5 a 10   ALTO        reaplicação diária
--     11 a 15  MODERADO    3x por semana
--     16 a 19  BAIXO       2x por semana
--     20       sem risco   conforme mudança de quadro
--
-- O número 15 é o mesmo nos dois; o sentido da comparação era o oposto.
--
-- Medido neste banco antes da correção, com limiar_moderado=15 e
-- limiar_alto NULL:
--     escore 8  -> 'baixo'     (é ALTO: avançaria de fase, sem Protocolo Vermelho)
--     escore 20 -> 'moderado'  (é sem risco: barraria avanço sem motivo)
--
-- Os limiares continuam na tabela de configuração, editáveis, como exige a
-- regra de segurança clínica. O que muda aqui é só a direção da comparação —
-- que não é parâmetro clínico, é a leitura correta do instrumento.
--
-- ⚠️ O limiar de risco e os destinatários do Protocolo Vermelho devem ser
-- validados e assinados pela equipe clínica da Rede Focoh antes de produção.
-- Um alerta que falha silenciosamente é um paciente sem socorro.
-- ============================================================================

create or replace function focoh_interno.tg_avaliacoes_risco_derivar_nivel()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, focoh_interno, pg_catalog
as $$
declare
  v_limiar_moderado int;
  v_limiar_alto     int;
begin
  select limiar_moderado, limiar_alto
    into strict v_limiar_moderado, v_limiar_alto
    from public.config_protocolo_vermelho
   where id = 1;

  -- `<=` e não `>=`: pontuação BAIXA é risco ALTO neste instrumento.
  -- `limiar_alto` NULL mantém o nível 'alto' inalcançável de propósito: é a
  -- forma de a configuração dizer "ainda não assinado pela equipe clínica".
  -- Quem preencher está assumindo a responsabilidade pelo valor.
  new.nivel := case
    when v_limiar_alto is not null and new.escore <= v_limiar_alto then 'alto'
    when new.escore <= v_limiar_moderado                           then 'moderado'
    else 'baixo'
  end::public.nivel_risco;

  return new;
end;
$$;

comment on function focoh_interno.tg_avaliacoes_risco_derivar_nivel() is
  'Deriva avaliacoes_risco.nivel do escore usando os limiares editáveis de config_protocolo_vermelho. Escala INVERTIDA: escore menor = risco maior.';

-- ----------------------------------------------------------------------------
-- A constraint de coerência dos limiares carregava a mesma inversão
-- ----------------------------------------------------------------------------
-- `limiar_alto >= limiar_moderado` era correto enquanto se acreditava numa
-- escala crescente. Na escala real, o limiar de risco ALTO é o menor dos dois
-- (5–10 alto, 11–15 moderado), então a checagem rejeitava justamente a
-- configuração certa: com moderado=15, ela recusava alto=10.
--
-- Idempotente de propósito: esta migration é reaplicada sobre bancos que já
-- rodaram a versão anterior dela.
alter table public.config_protocolo_vermelho
  drop constraint if exists config_pv_limiares_coerentes;

alter table public.config_protocolo_vermelho
  add constraint config_pv_limiares_coerentes
  check (limiar_alto is null or limiar_alto <= limiar_moderado);

comment on constraint config_pv_limiares_coerentes on public.config_protocolo_vermelho is
  'Escala invertida: o limiar de risco ALTO é numericamente MENOR que o de moderado.';
