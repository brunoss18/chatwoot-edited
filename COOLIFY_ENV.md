# Variáveis de ambiente — deploy no Coolify

**Este arquivo é documentação. Não contém valores, e nenhum valor deve ser
escrito aqui.** Tudo entra na aba **Environment Variables** do recurso no
Coolify. O `.env` está no `.gitignore` e nunca é commitado.

A coluna **Secreta?** indica o que marcar como secreto no Coolify (o painel
oculta o valor nos logs e na UI).

---

## As variáveis do Kanban são de RUNTIME

O módulo Kanban Clínico lê a URL e a `anon key` do Supabase de
`window.chatwootConfig`, montado pelo Rails a cada boot — não do bundle do Vite.
São variáveis de ambiente comuns: mudar qualquer uma vale com um **restart**, sem
rebuild e sem Build Variable.

| Variável | Secreta? | Onde marcar no Coolify |
|---|---|---|
| `FOCOH_SUPABASE_URL` | não | variável normal |
| `FOCOH_SUPABASE_ANON_KEY` | não | variável normal |

> As antigas `VITE_FOCOH_SUPABASE_URL` e `VITE_FOCOH_SUPABASE_ANON_KEY` foram
> substituídas no commit `9e1e6464de`. Se ainda estiverem cadastradas, podem ser
> apagadas: hoje são ignoradas.

Nenhuma das duas é segredo: a `anon key` é feita para viver no navegador, e é a
RLS do Supabase que isola o escore de risco de suicídio. O segredo do módulo é o
`FOCOH_SUPABASE_JWT_SECRET`, que fica só no Rails.

> **Nunca** cadastre a `service_role` key do Supabase. Ela tem `BYPASSRLS`: com
> ela no navegador, o isolamento do escore de risco deixa de existir.

---

## Obrigatórias — Chatwoot

| Variável | Secreta? | Como obter |
|---|---|---|
| `SECRET_KEY_BASE` | **sim** | Gerar (comando abaixo). Trocar depois invalida todas as sessões |
| `FRONTEND_URL` | não | A URL pública final, com `https://` e sem barra no fim. Ex.: `https://chat.seudominio.com` |
| `RAILS_ENV` | não | `production` — já fixo no compose, repetir aqui é inofensivo |
| `NODE_ENV` | não | `production` — idem |
| `INSTALLATION_ENV` | não | `docker` — idem |
| `RAILS_LOG_TO_STDOUT` | não | `true`, para os logs aparecerem no painel do Coolify |
| `FORCE_SSL` | não | `true` depois que o HTTPS estiver emitido. Ligar antes do certificado existir deixa o site inacessível |

### Sobre `ENABLE_ACCOUNT_SIGNUP`: não cadastre

Esta variável **não** é lida do ambiente depois da primeira subida.
`GlobalConfigService.load` consulta primeiro a tabela `installation_configs`, e
[config/installation_config.yml:61](config/installation_config.yml:61) já semeia
`ENABLE_ACCOUNT_SIGNUP: false`. Como o seed roda junto do
`db:chatwoot_prepare`, a linha no banco passa a existir e a env var é ignorada
para sempre.

Ou seja: cadastro público já nasce **desabilitado**, que é o que se quer numa
clínica. Para mudar depois, use **Super Admin → Settings**, não a env var.

E a primeira conta? Em produção o seed apenas liga uma flag no Redis
(`CHATWOOT_INSTALLATION_ONBOARDING`), e o app redireciona para
`/installation/onboarding`, onde você cria o super admin. Esse caminho é
independente do `ENABLE_ACCOUNT_SIGNUP`.

> Consequência de ordem, que vale ouro no primeiro deploy: **o Redis precisa
> estar configurado e acessível ANTES de rodar as migrations**, porque o seed
> escreve essa flag nele. Sem Redis, o seed falha, a flag não é criada e não há
> como criar a primeira conta.

Gerar o `SECRET_KEY_BASE` no Windows PowerShell:

```powershell
-join ((1..64) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })
```

Produz 128 caracteres hexadecimais (64 bytes). Copie a saída inteira.

---

## PostgreSQL — do recurso Coolify

> O recurso Postgres do Coolify precisa usar a imagem **`pgvector/pgvector:pg16`**,
> não a imagem padrão. O `db/schema.rb` do Chatwoot exige a extensão `vector`, e
> ela **não existe** na imagem oficial do PostgreSQL — `CREATE EXTENSION vector`
> falha com *extension is not available*. Detalhes no `DEPLOY_COOLIFY.md`.

| Variável | Secreta? | Como obter |
|---|---|---|
| `POSTGRES_HOST` | não | Hostname **interno** do recurso Postgres no Coolify (não `localhost`, não IP público) |
| `POSTGRES_PORT` | não | `5432` |
| `POSTGRES_USERNAME` | não | Usuário do recurso Postgres. Atenção ao nome: é `POSTGRES_USERNAME`, não `POSTGRES_USER` |
| `POSTGRES_PASSWORD` | **sim** | Senha gerada pelo Coolify ao criar o recurso |
| `POSTGRES_DATABASE` | não | Ex.: `chatwoot` |
| `POSTGRES_STATEMENT_TIMEOUT` | não | **Deixe em branco.** O padrão é `14s` e serve de proteção em runtime. Os 600s necessários às migrations são passados só no comando de migration, não aqui |

Alternativa: em vez das cinco acima, uma única `DATABASE_URL`. O entrypoint
prioriza ela e não a imprime nos logs
([docker/entrypoints/helpers/pg_database_url.rb](docker/entrypoints/helpers/pg_database_url.rb)).
Se usar, marque como **secreta** — ela contém a senha.

---

## Redis — do recurso Coolify

| Variável | Secreta? | Como obter |
|---|---|---|
| `REDIS_URL` | **sim** | Do recurso Redis, usando o host interno. Formato: `redis://:SENHA@host-interno:6379` — os dois-pontos antes da senha são obrigatórios (usuário vazio) |
| `REDIS_PASSWORD` | **sim** | Senha do recurso. Necessária mesmo já estando embutida na `REDIS_URL`: o Sidekiq a lê separadamente em algumas configurações |
| `REDIS_OPENSSL_VERIFY_MODE` | não | Só se usar `rediss://` (TLS) com certificado próprio. Valor `none` |

---

## E-mail / SMTP — pode ficar em branco para subir

Sem SMTP a aplicação sobe e funciona; o que não funciona é convite de agente,
recuperação de senha e notificação por e-mail. Dá para configurar depois.

| Variável | Secreta? | Como obter |
|---|---|---|
| `MAILER_SENDER_EMAIL` | não | Remetente. Ex.: `Rede Focoh <nao-responda@seudominio.com>` |
| `SMTP_ADDRESS` | não | Host do provedor. Ex.: `smtp.sendgrid.net` |
| `SMTP_PORT` | não | `587` para STARTTLS, `465` para SSL |
| `SMTP_USERNAME` | não | Usuário do provedor (no SendGrid, literalmente `apikey`) |
| `SMTP_PASSWORD` | **sim** | Senha ou API key |
| `SMTP_AUTHENTICATION` | não | `plain`, `login` ou `cram_md5` |
| `SMTP_ENABLE_STARTTLS_AUTO` | não | `true` na porta 587 |
| `SMTP_DOMAIN` | não | Domínio HELO, normalmente o seu domínio |

---

## Módulo Kanban Clínico (Supabase)

Varredura no código deste fork por `import.meta.env`, `ENV.fetch` e `ENV[`
encontrou **exatamente três** variáveis do módulo — as duas de runtime listadas
no topo, mais esta:

| Variável | Secreta? | Onde é lida | Como obter |
|---|---|---|---|
| `FOCOH_SUPABASE_JWT_SECRET` | **sim** | [app/services/focoh/supabase_token_service.rb:77](app/services/focoh/supabase_token_service.rb:77) | Supabase → Settings → API → **JWT Secret** |
| `FOCOH_SUPABASE_URL` | não | [useFocohKanban.js](app/javascript/dashboard/routes/dashboard/kanban/useFocohKanban.js) via `useConfig()` | Supabase → Settings → API → Project URL |
| `FOCOH_SUPABASE_ANON_KEY` | não | idem | Supabase → Settings → API → `anon` `public` |

Com o `FOCOH_SUPABASE_JWT_SECRET` é possível forjar qualquer papel clínico e a
RLS deixa de isolar o escore. Ele fica só no servidor, nunca em build arg.

O board também exige, do lado do Supabase, que as migrations de
`supabase/migrations/` estejam aplicadas e que o usuário tenha papel clínico
atribuído — ver [supabase/README.md](supabase/README.md).

---

## Recomendadas

| Variável | Secreta? | Como obter |
|---|---|---|
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | **sim** | Necessárias para MFA/2FA. Gere as três de uma vez no terminal do serviço `rails`: `bundle exec rails db:encryption:init` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | **sim** | idem |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | **sim** | idem |
| `DEFAULT_LOCALE` | não | `pt_BR` |
| `RAILS_MAX_THREADS` | não | `5` é o padrão. Baixe se o servidor tiver pouca RAM |
| `SIDEKIQ_CONCURRENCY` | não | `10` é o padrão. Baixe junto com o acima em servidor pequeno |

São opcionais no boot (o código as usa só `if present?`), mas sem elas o 2FA
não funciona — e vale ligar 2FA num sistema com dado clínico.

### Armazenamento de anexos

O compose monta o volume `storage_data`, então uploads funcionam em disco local
sem configurar nada. Para S3, defina `ACTIVE_STORAGE_SERVICE=amazon` mais
`AWS_ACCESS_KEY_ID` (**secreta**), `AWS_SECRET_ACCESS_KEY` (**secreta**),
`AWS_REGION` e `S3_BUCKET_NAME`.

---

## WhatsApp por QR Code (Baileys)

Com o `docker-compose.coolify-teste.yaml` o serviço `baileys-api` já vem
declarado e conectado. **A única variável que você cadastra é a chave:**

| Variável | Secreta? | Observação |
|---|---|---|
| `BAILEYS_API_KEY` | **sim** | Qualquer string longa e aleatória, inventada por você. O serviço a cria no primeiro boot e o Rails a usa para autenticar |
| `BAILEYS_CLIENT_NAME` | não | Opcional. Aparece como nome do dispositivo no WhatsApp. Padrão: `Chatwoot Focoh` |
| `BAILEYS_WHATSAPP_GROUPS_ENABLED` | não | Opcional, `false` por padrão |

Gere a chave com:

```
openssl rand -hex 32
```

O resto o compose já resolve e você não precisa cadastrar:
`BAILEYS_PROVIDER_DEFAULT_URL` (fixo em `http://baileys-api:3025`),
`BAILEYS_PROVIDER_USE_INTERNAL_HOST_URL` e o `NODE_ENV` do serviço.

### Três coisas que quebram isto, e já quebraram

**A versão do `baileys-api` acompanha a do Chatwoot.** Este fork é 4.17.x e o par
é a **v3.7.2**. A v3.2.0 pareia com o Chatwoot 4.14.x. Trocar uma sem a outra
quebra o contrato de webhook entre os dois.

**O serviço exige `NODE_ENV=production`.** Fora de produção o logger dele importa
`pino-caller`, que não está no bundle da imagem, e o container entra em loop de
restart com `Cannot find package pino-caller`. O compose já define isso — se você
escrever o seu próprio, não esqueça.

**A sessão pareada mora no Redis**, na chave
`@baileys-api:connections:<numero>:authState`, e não em disco. Perder o volume do
Redis é perder o pareamento e ter de ler o QR de novo. Para migrar de VPS sem
reparear, copie essa chave — com o serviço antigo **derrubado antes**, porque o
WhatsApp admite uma conexão por sessão e dois serviços no ar com a mesma
credencial a invalidam.


---

## Conferência rápida antes do primeiro deploy

Mínimo para a aplicação subir e responder:

```
SECRET_KEY_BASE          FRONTEND_URL             RAILS_LOG_TO_STDOUT
POSTGRES_HOST            POSTGRES_PORT            POSTGRES_USERNAME
POSTGRES_PASSWORD        POSTGRES_DATABASE        REDIS_URL
```

Mais, para o Kanban Clínico funcionar:

```
FOCOH_SUPABASE_JWT_SECRET
FOCOH_SUPABASE_URL
FOCOH_SUPABASE_ANON_KEY
```

`FORCE_SSL=true` só **depois** que o certificado estiver emitido.
