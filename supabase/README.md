# Kanban Clínico — Rede Focoh

Módulo de acompanhamento da jornada do paciente, acessível pelo item **Kanban**
na sidebar do Chatwoot. O Supabase é o sistema-fonte dos dados clínicos; o
Chatwoot é a interface. Nada de clínico é replicado no Postgres do Chatwoot.

```
Formulário eletrônico (laudo / admissão / ficha de risco)
        │
        ▼
   Supabase (Postgres)  ──►  triggers e constraints impõem as travas
        │   ▲                RLS isola o escore de risco de suicídio
        │   │                outbox garante que nenhum alerta se perca sem rastro
        ▼   │
  Módulo Kanban (Vue, dentro do fork)
        │        · rota /app/accounts/:accountId/kanban
        │        · board de 6 colunas, drag-and-drop
        │        · cartão mostra flags, nunca o escore
        ▼
  Webhooks (Copa · Protocolo Vermelho · cobrança de laudos)
```

**Princípio que governa o módulo:** toda trava clínica mora no banco. O board
Vue apenas reflete o que o banco permite — ele desabilita botão e mostra
mensagem, mas a decisão é do Postgres. Regra que morasse só no frontend seria
contornável por um request direto ao PostgREST.

---

## 1. Ordem de execução das migrations

As migrations são idempotentes na ordem, **não** individualmente: rode todas, em
ordem lexicográfica do nome do arquivo. Com o Supabase CLI:

```bash
supabase db reset
```

Isso aplica `supabase/migrations/*.sql` em ordem e em seguida `supabase/seed.sql`.

| # | Arquivo | O que estabelece |
|---|---------|------------------|
| 01 | `..._extensions.sql` | `pg_net` e `pg_cron`. **Falha aqui é diagnóstico**, não acidente: sem elas não há transporte de webhook nem reconciliação de entrega |
| 02 | `..._enums_e_helpers.sql` | Enum das 6 colunas (na ordem da jornada), schema interno `focoh_interno`, helpers de papel, textos oficiais de bloqueio |
| 03 | `..._tabelas.sql` | As 7 tabelas clínicas, constraints e índices (as 6 restantes nascem com os gatilhos, nas migrations 10 a 13) |
| 04 | `..._nivel_risco_derivado.sql` | `nivel` derivado do escore pelos limiares configurados |
| 05 | `..._trava_avanco_fase.sql` | **Regra Anexo Fases** (ver §6) |
| 06 | `..._trava_saida_juridica.sql` | Arquivar exige coluna 6 + Termo de Saída assinado |
| 07 | `..._trava_visitas_30_dias.sql` | Sem visita nos primeiros 30 dias de internação |
| 08 | `..._cards_do_quadro.sql` | A única porta de leitura do board |
| 09 | `..._rls.sql` | RLS e privilégios das tabelas clínicas |
| 10 | `..._webhooks_infra.sql` | Outbox, config de endpoints, despacho e reconciliação |
| 11 | `..._gatilho_copa.sql` | Gatilho 1 |
| 12 | `..._gatilho_protocolo_vermelho.sql` | Gatilho 2 + UPCI + auditoria de disparo |
| 13 | `..._gatilho_cobranca_laudos.sql` | Gatilho 3 |
| 14 | `..._agendamentos_cron.sql` | As três rotinas `pg_cron` |
| 15 | `..._rls_gatilhos.sql` | RLS das tabelas dos gatilhos |

`supabase/seed.sql` cria seis pacientes fictícios (prefixo `[TESTE]`) que
reproduzem os cenários de trava. **Não use em produção.** O seed não desliga
triggers: dois pacientes chegam à coluna 6 passando pela própria trava de
avanço, um passo por vez — se alguma trava estiver quebrada, o seed falha.

---

## 2. Variáveis de ambiente

No `.env` do Chatwoot (há um bloco comentado no `.env.example`):

| Variável | Onde vive | Para quê |
|----------|-----------|----------|
| `VITE_FOCOH_SUPABASE_URL` | navegador | URL do projeto Supabase |
| `VITE_FOCOH_SUPABASE_ANON_KEY` | navegador | **Sempre a anon key.** A RLS é o que isola o escore de risco |
| `FOCOH_SUPABASE_JWT_SECRET` | servidor | Assina o JWT curto do board (Settings → API → JWT Secret) |

As duas `VITE_*` são lidas em tempo de build — **mudá-las exige rebuild do
frontend**. Ausência delas não deixa o board vazio: ele diz na tela que não está
configurado, porque quadro vazio se confundiria com clínica sem pacientes.

> **A `service_role` key e o `FOCOH_SUPABASE_JWT_SECRET` nunca devem chegar ao
> navegador.** A primeira tem `BYPASSRLS`; com o segundo é possível forjar
> qualquer papel clínico. Nos dois casos o isolamento do escore de risco deixa
> de existir.

### Ponte de autenticação

A sessão do Chatwoot vira uma sessão Supabase assim:

```
POST /api/v1/accounts/:account_id/focoh/supabase_token
  → { access_token, expires_at }
```

`Focoh::SupabaseTokenService` assina um JWT de **15 minutos** com
`role: authenticated` e o papel clínico em `app_metadata.role`, que é onde a RLS
o procura. O `sub` é um UUIDv5 derivado do id do usuário Chatwoot — estável
entre sessões, o que mantém a autoria rastreável.

> `IDENTITY_NAMESPACE`, no service, **nunca deve ser alterado**: mudá-lo troca o
> `sub` de todo mundo e desassocia o histórico de autoria (laudos aprovados,
> fichas de risco lançadas).

---

## 3. Papéis clínicos

O papel clínico é independente do RBAC do Chatwoot. O Chatwoot decide **quem
abre o Kanban** (`agent` / `administrator`, via `meta.permissions` da rota); o
Supabase decide **o que a pessoa vê e pode fazer** (via RLS).

Sete papéis, definidos em `focoh_interno.papeis_focoh()`:

| Papel | Vê o board | Move cartões | Vê o escore de risco |
|-------|-----------|--------------|----------------------|
| `recepcao` | sim | sim | **não** |
| `gerente_familias` | sim | sim | **não** |
| `medico_psiquiatra` | sim | sim | sim |
| `psicologo` | sim | sim | sim |
| `enfermeiro_rt` | sim | sim | sim |
| `coordenacao_tecnica` | sim | sim | sim |
| `diretor_geral` | sim | sim | sim |

Os cinco últimos formam a **equipe clínica**
(`focoh_interno.papeis_equipe_clinica()`). Para recepção e Gerente de Famílias a
tabela `avaliacoes_risco` simplesmente não tem linhas — é esse isolamento que
sustenta a afirmação de que o escore não vaza pelo board.

### Como atribuir

O papel vive em `User#custom_attributes['focoh_clinical_role']` no Chatwoot:

```bash
bundle exec rails runner "u = User.find_by(email: 'medico@focoh.com.br'); u.update!(custom_attributes: u.custom_attributes.to_h.merge('focoh_clinical_role' => 'medico_psiquiatra'))"
```

Papel ausente ou fora da lista → o endpoint responde **403** e o board explica o
motivo na tela. A lista é validada em Ruby *e* em SQL de propósito: sem a
validação no Ruby, um papel escrito errado viraria um quadro vazio (a RLS não
devolveria linha) em vez de um erro visível.

---

## 4. Configuração pós-migration

Três tabelas de configuração nascem com valores documentados mas **não
operacionais**. Isso é intencional: preencher é ato de configuração humana.

### `config_protocolo_vermelho` (singleton, `id = 1`)

| Campo | Nasce como | Precisa |
|-------|-----------|---------|
| `limiar_moderado` | `15` (valor documentado, escala 1–20) | confirmação clínica |
| `limiar_alto` | `NULL` | **definição clínica** — a documentação Rede Focoh não fornece este corte |
| `destinatarios` | 5 funções, `whatsapp: null` | os cinco números |
| `validado_clinicamente` | `false` | assinatura (ver §7) |

Enquanto `limiar_alto` é `NULL`, nada é classificado como Alto
automaticamente. **Não há lacuna de segurança**: Moderado já dispara o Protocolo
Vermelho e já barra o avanço de fase.

### `config_webhooks` (uma linha por evento)

`url` nasce `NULL` nos quatro eventos. Com `url` nula, o alerta vai para
`estado = 'falhou'` com `endpoint_nao_configurado` e **aparece na view de
alertas não entregues** — em vez de desaparecer.

O contrato do receptor é `POST` JSON com o `payload` da linha do outbox.

> `config_webhooks.headers` guarda o cabeçalho de autenticação do endpoint, ou
> seja **contém segredo**. A RLS restringe leitura ao `diretor_geral`. Em
> produção, prefira guardar o token no Supabase Vault. Quem lê esse cabeçalho
> pode forjar um alerta de Protocolo Vermelho — ou, pior, redirecionar os
> verdadeiros trocando a URL.

### `config_cobranca_laudos` (singleton, `id = 1`)

`dia_semana = 1` (segunda), `hora_envio = 08:00`,
`hora_escalonamento = 12:00`, no fuso de `focoh_interno.fuso()`.
`url_formulario_base` nasce `NULL`. `destinatarios` e
`destinatarios_escalonamento` nascem com `whatsapp: null`.

Os horários **não** estão no agendamento do `pg_cron`: a rotina roda a cada 15
minutos e pergunta "é hora?". Mudar o horário é editar uma linha, sem reagendar
cron nem fazer deploy.

---

## 5. Códigos de erro (contrato com o frontend)

O painel exibe a mensagem que **vem do banco** — fonte única da copy oficial — e
usa o SQLSTATE só para escolher o formato (modal para bloqueio de fase, toast
para o resto).

| Código | Significado |
|--------|-------------|
| `FCH01` | Avanço de fase bloqueado (Anexo Fases) |
| `FCH02` | Arquivamento bloqueado (trava de saída jurídica) |
| `FCH03` | Visita bloqueada nos primeiros 30 dias |
| `FCH04` | Paciente arquivado: fase imutável |
| `FCH05` | Regressão de fase exige papel da equipe clínica |
| `FCH06` | A jornada é sequencial: uma coluna por vez |
| `FCH07` | Admissão só pela coluna 1 |
| `FCH08` | Encerrar a UPCI é decisão clínica |

Atenção: a RLS nega **por filtro, não por erro**. Um `UPDATE` sem permissão casa
com zero linhas e retorna sucesso com `0 affected` — não vem mensagem alguma.
Isso é o oposto das travas de fase, que gritam.

---

## 6. As regras que o banco impõe

**Avanço de fase (Anexo Fases).** Mover para a coluna seguinte exige, na semana
vigente: Laudo Clínico + Terapêutico + Disciplinar aprovados **e** nível de
risco Baixo. Risco Moderado ou Alto barra mesmo com os 3 laudos.

> *"A progressão não ocorre por tempo, pressão ou percepção subjetiva — só
> quando todos os critérios mínimos estão atendidos."*

Paciente **sem nenhuma** ficha de risco também é barrado: "sem avaliação" não é
"risco baixo", e a escala de risco é tarefa da própria coluna 1.

**Trava de saída jurídica.** Arquivar exige estar na coluna 6 e ter Termo de
Saída assinado. Entrar na coluna 6 e arquivar são dois atos: se entrar já
arquivasse, o paciente sairia do board antes do pós-alta, que a documentação
coloca *dentro* da coluna 6.

**Auditoria.** `auditoria_transicoes_fase` registra apenas transições
efetivadas. Tentativa bloqueada levanta exceção, e a exceção desfaz a transação
— um INSERT de auditoria feito antes do `RAISE` seria revertido junto.
Tentativas negadas saem por `RAISE WARNING` no log do Postgres.

**Monitorar em produção:**

```sql
select * from public.protocolo_vermelho_alertas_nao_entregues;
```

**Linha nesta view = paciente cujo Protocolo Vermelho foi ordenado e não se
comprovou entrega.**

---

## 7. ⚠️ Checklist de validação clínica — assinar antes de produção

> **O limiar de risco e os destinatários do Protocolo Vermelho devem ser
> validados e assinados pela equipe clínica da Rede Focoh antes de produção.
> Um alerta que falha silenciosamente é um paciente sem socorro.**

Nada abaixo pode ser decidido por quem escreve o código.

### Protocolo Vermelho

- [ ] `limiar_moderado = 15` (escala 1–20) confirmado pela equipe clínica
- [ ] `limiar_alto` **definido** — hoje é `NULL` porque a documentação não o fornece
- [ ] WhatsApp corporativo do **Médico Psiquiatra de Referência**
- [ ] WhatsApp corporativo do **Enfermeiro Responsável Técnico**
- [ ] WhatsApp corporativo da **Coordenação Técnica**
- [ ] WhatsApp corporativo do **Gerente de Famílias do Caso**
- [ ] WhatsApp corporativo do **Diretor Geral**
- [ ] Confirmado que o alerta **não** deve conter escore, nível nem detalhes de ideação (decisão atual: não contém, porque WhatsApp é canal inseguro e encaminhável)

### Comportamento de falha de entrega

- [ ] Definido **quem** monitora `protocolo_vermelho_alertas_nao_entregues`
- [ ] Definida a **frequência** de verificação
- [ ] Definido o **plano de contingência** quando a entrega falha — qual canal alternativo, em quanto tempo, acionado por quem
- [ ] Definido se `max_tentativas` (padrão 5) e o `timeout` (5s) são adequados
- [ ] Confirmado que uma instalação sem endpoint configurado deve **falhar visivelmente** (comportamento atual) e não silenciosamente

### Acesso ao dado sensível

- [ ] Confirmada a composição da **equipe clínica** que vê o escore: médico psiquiatra, psicólogo, enfermeiro RT, coordenação técnica, diretor geral
- [ ] Confirmado que **recepção e Gerente de Famílias** veem apenas o flag "Protocolo Vermelho ativo" e "pendência clínica", nunca a pontuação
- [ ] Confirmado que `pendencia_clinica` no cartão **não distingue** risco Moderado de Alto

### Regras de fase

- [ ] Confirmado o mapa de quem aprova cada laudo: Clínico → médico psiquiatra; Terapêutico → psicólogo; Disciplinar → coordenação técnica
- [ ] Confirmado que paciente **sem ficha de risco** deve ser barrado
- [ ] Confirmado que **regressão de fase** é permitida à equipe clínica
- [ ] Confirmada a janela de **30 dias** sem visitas, contada da admissão

### Textos oficiais

- [ ] Mensagem de `FCH01` confirmada (texto oficial já aplicado literalmente)
- [ ] **Redigir e aprovar** o texto de `FCH02` — a redação atual é provisória e está marcada como `AGUARDANDO TEXTO OFICIAL` no código

### Cobrança de laudos

- [ ] Horários confirmados: envio 08h00, escalonamento 12h00, segunda-feira
- [ ] `url_formulario_base` do formulário eletrônico
- [ ] WhatsApps de destino da cobrança e do escalonamento

### Liberação

- [ ] `config_protocolo_vermelho.validado_clinicamente = true`, com `validado_por` e `validado_em` preenchidos

```sql
update public.config_protocolo_vermelho
   set validado_clinicamente = true,
       validado_por = 'Nome e registro profissional de quem assina',
       validado_em  = now()
 where id = 1;
```

O deploy de produção deve **checar esse campo** e recusar subir enquanto for
`false`.

Assinado por: ______________________  Data: ____ / ____ / ______

---

## 8. Testes

O harness aplica migrations e seed num Postgres real embarcado (PGlite/WASM) e
exercita cada trava com o papel de quem faria a operação no board. Não precisa
de Docker.

```bash
cd supabase/tests && npm install && npm test
```

**Fronteira do teste, explícita.** O harness pula apenas a migration 01
(extensões nativas não instalam em WASM) e injeta stubs de `net` e `cron`. Ele
prova que o gatilho **ordena** o alerta, que o payload não leva escore, que a
auditoria registra o disparo e que a falha de entrega fica visível. Ele **não**
prova que um POST atravessa a internet — isso depende do endpoint real e é
verificação de ambiente, não de regra clínica.

A garantia que mais importa é a primeira, e essa é Postgres puro: o outbox é
gravado na mesma transação da ficha de risco, sem stub no caminho.

Não substitui `supabase db reset` contra o projeto real.

---

## 9. O que ainda não está pronto

- **Nenhum WhatsApp é enviado** até que `config_webhooks.url` aponte para um
  receptor. O receptor é o ponto de extensão documentado (§4) e usaria o canal
  WhatsApp do próprio fork.
- **`limiar_alto` é `NULL`** — pendente de definição clínica.
- **Texto de `FCH02`** é provisório.
- O board **não** tem ainda a ação de arquivar na coluna 6; a trava jurídica
  está implementada e testada no banco, mas a UI que a aciona não foi feita.
