# Variáveis de ambiente — deploy no Coolify

**Este arquivo é documentação. Não contém valores, e nenhum valor deve ser
escrito aqui.** Tudo entra na aba **Environment Variables** do recurso no
Coolify. O `.env` está no `.gitignore` e nunca é commitado.

A coluna **Secreta?** indica o que marcar como secreto no Coolify (o painel
oculta o valor nos logs e na UI).

---

## ⚠️ Antes de tudo: duas variáveis são de BUILD, não de runtime

O módulo Kanban Clínico lê duas variáveis via `import.meta.env`, e o Vite as
grava no bundle JavaScript durante `assets:precompile` — que acontece **no build
da imagem**, não quando o container sobe.

| Variável | Secreta? | Onde marcar no Coolify |
|---|---|---|
| `VITE_FOCOH_SUPABASE_URL` | não | marcar **Build Variable** |
| `VITE_FOCOH_SUPABASE_ANON_KEY` | não | marcar **Build Variable** |

Cadastrá-las apenas como variável de runtime **não funciona**: o board sobe
dizendo "O Kanban Clínico não está configurado nesta instalação". Se isso
acontecer, marque as duas como Build Variable e **refaça o deploy** — mudança
nelas exige rebuild, não só restart.

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
encontrou **exatamente três** variáveis do módulo — as duas de build listadas no
topo, mais esta:

| Variável | Secreta? | Onde é lida | Como obter |
|---|---|---|---|
| `FOCOH_SUPABASE_JWT_SECRET` | **sim** | [app/services/focoh/supabase_token_service.rb:77](app/services/focoh/supabase_token_service.rb:77) | Supabase → Settings → API → **JWT Secret** |
| `VITE_FOCOH_SUPABASE_URL` | não | [useFocohKanban.js:18](app/javascript/dashboard/routes/dashboard/kanban/useFocohKanban.js:18) | Supabase → Settings → API → Project URL. **Build Variable** |
| `VITE_FOCOH_SUPABASE_ANON_KEY` | não | [useFocohKanban.js:19](app/javascript/dashboard/routes/dashboard/kanban/useFocohKanban.js:19) | Supabase → Settings → API → `anon` `public`. **Build Variable** |

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

## Específicas deste fork (opcionais)

Este fork inclui o provedor WhatsApp Baileys. Só preencha se for usar; exige um
serviço `baileys-api` separado.

| Variável | Secreta? | Observação |
|---|---|---|
| `BAILEYS_PROVIDER_DEFAULT_URL` | não | URL do baileys-api. O default do `.env.example` é `http://localhost:3025`, que **não** vale dentro do container |
| `BAILEYS_PROVIDER_DEFAULT_API_KEY` | **sim** | Chave do baileys-api |
| `BAILEYS_PROVIDER_DEFAULT_CLIENT_NAME` | não | Ex.: `Chatwoot` |
| `WHATSAPP_GROUPS_ENABLED` | não | `false` por padrão |
| `BAILEYS_WHATSAPP_GROUPS_ENABLED` | não | `false` por padrão |

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
VITE_FOCOH_SUPABASE_URL          (Build Variable)
VITE_FOCOH_SUPABASE_ANON_KEY     (Build Variable)
```

`FORCE_SSL=true` só **depois** que o certificado estiver emitido.
