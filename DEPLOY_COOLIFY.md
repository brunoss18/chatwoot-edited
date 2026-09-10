# Deploy do fork Chatwoot (Rede Focoh) no Coolify

Guia do que fazer **na interface do Coolify**. O repositório já está preparado:
[docker-compose.coolify.yaml](docker-compose.coolify.yaml) builda a imagem a
partir deste código, e a lista de variáveis está em
[COOLIFY_ENV.md](COOLIFY_ENV.md).

**Leia antes de começar:**

- Postgres e Redis são recursos **separados** no Coolify. O compose não os sobe.
- O Postgres **precisa** da imagem `pgvector/pgvector:pg16`, não a padrão (passo 2).
- Duas variáveis são **build args**, não runtime (passo 5).
- Migrations **não** rodam no boot. É passo próprio (passo 8).
- O Redis precisa estar de pé **antes** das migrations, senão você não consegue
  criar a primeira conta (explicado no passo 8).

Ordem sugerida: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9.

---

## 1. Conectar o repositório privado

**Settings → Sources → + Add → GitHub App.**

1. Dê um nome à source (ex.: `github-brunoss18`).
2. Siga o fluxo de criação do GitHub App e instale-o na sua conta.
3. Em **Repository access**, autorize o repositório `chatwoot-edited`. Pode
   autorizar só ele.
4. Volte ao Coolify e confirme que a source aparece como conectada.

**Alternativa (deploy key SSH),** se preferir não criar um GitHub App:

1. No Coolify, **Keys & Tokens → Private Keys → + Add**, e gere um par.
2. Copie a chave **pública**.
3. No GitHub: repositório → **Settings → Deploy keys → Add deploy key**, cole a
   pública, **sem** marcar *Allow write access*.
4. Ao criar o app no passo 4, escolha **Public Repository / Git with SSH** e
   informe `git@github.com:brunoss18/chatwoot-edited.git` com essa chave.

---

## 2. Criar o PostgreSQL — com pgvector

**+ New → Database → PostgreSQL.**

> ⚠️ **Troque a imagem antes de fazer o deploy do banco.** O `db/schema.rb` do
> Chatwoot exige a extensão `vector`, que **não existe** na imagem oficial do
> PostgreSQL. Rodar `CREATE EXTENSION vector` numa imagem padrão falha com
> *extension "vector" is not available* — não é questão de habilitar, o binário
> não está lá.

1. No campo de imagem/versão do recurso, use **`pgvector/pgvector:pg16`**.
   É exatamente a imagem que os composes oficiais do Chatwoot usam.
2. Defina o nome do banco como `chatwoot` (ou anote o que usar).
3. Faça o deploy do recurso.
4. Abra o **Terminal** do recurso e crie as extensões:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

O schema também declara `pg_stat_statements`; ela vem no contrib e o próprio
`db:chatwoot_prepare` a cria. `plpgsql` já vem por padrão.

5. **Anote, da aba de conexão do recurso:** host **interno**, porta, usuário,
   senha e nome do banco. Use o host interno, nunca `localhost` nem IP público.

> Atenção ao nome da variável mais adiante: o Chatwoot lê `POSTGRES_USERNAME`,
> enquanto o Coolify chama o campo dele de `POSTGRES_USER`. Copiar o nome errado
> deixa o container em loop no `pg_isready`.

---

## 3. Criar o Redis

**+ New → Database → Redis.**

1. Faça o deploy com a configuração padrão.
2. Anote a **URL interna** e a senha. A `REDIS_URL` fica assim:

```
redis://:SENHA@host-redis-interno:6379
```

Os dois-pontos antes da senha são obrigatórios — é o usuário vazio.

---

## 4. Criar a aplicação

**+ New → Application → Docker Compose** (em algumas versões:
*Docker Compose Empty* / *Based on Docker Compose*).

1. Escolha a source do passo 1 e o repositório `chatwoot-edited`.
2. **Branch:** a branch que você quer implantar (ex.: `main` ou a branch de
   deploy dedicada).
3. **Docker Compose file location:** `docker-compose.coolify.yaml`
   (em algumas versões o campo pede `/docker-compose.coolify.yaml`).
4. **Base directory:** `/`.
5. Salve **sem** fazer deploy ainda — falta cadastrar as variáveis.

O Coolify deve detectar dois serviços: **`rails`** e **`sidekiq`**. Se aparecer
um terceiro chamado `base`, o arquivo errado foi selecionado — o compose de
produção do Chatwoot tem esse serviço fantasma, o nosso não.

---

## 5. Cadastrar as variáveis de ambiente

Aba **Environment Variables** do app. A lista completa, com "como obter" e o que
é secreto, está em [COOLIFY_ENV.md](COOLIFY_ENV.md).

Mínimo para subir:

```
SECRET_KEY_BASE          FRONTEND_URL             RAILS_LOG_TO_STDOUT
POSTGRES_HOST            POSTGRES_PORT            POSTGRES_USERNAME
POSTGRES_PASSWORD        POSTGRES_DATABASE        REDIS_URL
REDIS_PASSWORD
```

Mais, para o Kanban Clínico:

```
FOCOH_SUPABASE_JWT_SECRET
VITE_FOCOH_SUPABASE_URL          ← marcar "Build Variable"
VITE_FOCOH_SUPABASE_ANON_KEY     ← marcar "Build Variable"
```

Regras:

- Marque como **secretas**: `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `REDIS_URL`,
  `REDIS_PASSWORD`, `SMTP_PASSWORD`, `FOCOH_SUPABASE_JWT_SECRET` e as chaves de
  `ACTIVE_RECORD_ENCRYPTION_*`.
- Marque como **Build Variable** as duas `VITE_FOCOH_*`. Elas são gravadas no
  bundle JavaScript durante o build; como variável de runtime **não têm efeito**.
- **Não** cadastre `POSTGRES_STATEMENT_TIMEOUT` (o padrão de 14s é proteção em
  runtime; os 600s das migrations vão no comando do passo 8).
- **Não** cadastre `ENABLE_ACCOUNT_SIGNUP` — o valor vem do banco, não do
  ambiente, e já nasce desabilitado. Detalhes no `COOLIFY_ENV.md`.
- Deixe `FORCE_SSL` de fora por enquanto. Ligue depois do passo 6.

---

## 6. Domínio e HTTPS

**Aponte o DNS ANTES**, senão o Let's Encrypt não consegue validar e o
certificado não é emitido:

1. No seu provedor de DNS, crie um registro **A** do subdomínio (ex.:
   `chat.seudominio.com`) para o **IP do servidor Coolify**.
2. Espere propagar. Verifique no PowerShell:

```powershell
Resolve-DnsName chat.seudominio.com -Type A
```

3. No Coolify, no **serviço `rails`** (não no `sidekiq`), preencha o domínio:
   `https://chat.seudominio.com`.
4. Confirme que `FRONTEND_URL` tem exatamente essa URL, com `https://` e **sem**
   barra no final.
5. Deixe o Coolify emitir o certificado (Let's Encrypt, automático).

Depois que o HTTPS estiver funcionando, acrescente `FORCE_SSL=true` nas
variáveis e faça restart. Ligar antes do certificado existir deixa o site
inacessível.

---

## 7. Primeiro deploy

Clique em **Deploy**.

**Espere de 10 a 20 minutos.** O build compila gems nativas (grpc, nokogiri) e
roda `assets:precompile` com Vite. Não é travamento.

**Recursos do servidor:** o `docker/Dockerfile` roda o build de assets com
`NODE_OPTIONS=--max-old-space-size=4096`, ou seja o Node pode pedir ~4 GB só
para o heap. Some as gems nativas compilando em paralelo.

- **Mínimo realista: 4 GB de RAM + swap.**
- **Recomendado: 8 GB.**
- Com 2 GB e sem swap, o build morre com `Killed` (OOM) — ver troubleshooting.

Acompanhe os logs de build no painel. O deploy termina com dois containers
rodando: `rails` e `sidekiq`.

---

## 8. Rodar as migrations (uma vez, e em cada release)

> **Confirme que o Redis está de pé e que `REDIS_URL` está correta antes disto.**
> Em produção, o seed do Chatwoot grava a flag `CHATWOOT_INSTALLATION_ONBOARDING`
> **no Redis** — é ela que libera a tela de criação da primeira conta. Sem
> Redis, o seed falha, a flag não nasce, e você fica sem como criar o super admin.

O comando é:

```bash
POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare
```

Por que assim, e não no boot do container: `docker/entrypoints/rails.sh` **não**
roda migrations, e o próprio Chatwoot usa fase de *release* para isso
(`Procfile`). Rodar no boot faria `rails` e `sidekiq` competirem — e o ramo de
banco novo, que carrega schema e faz seed, não é protegido pelo advisory lock do
`db:migrate`. Os `600s` ficam escopados ao comando porque o
`statement_timeout` padrão é 14s e serve de proteção para as queries normais da
aplicação.

**Opção A — Pre-deployment Command (preferida).** Em **Configuration →
Pre-deployment Command**, cole o comando acima e selecione o container do
serviço `rails`. A task é **idempotente**: em banco novo carrega schema e faz
seed; em banco existente só aplica migrations pendentes. Então rodar em todo
deploy é o comportamento correto, e futuras atualizações do fork migram sozinhas.

**Opção B — manual, se a sua versão não tiver esse campo.** Abra o **Terminal**
do serviço `rails` e rode o mesmo comando. Repita a cada atualização que traga
migration nova.

---

## 9. Verificação pós-deploy

1. Acesse `https://chat.seudominio.com`. Você deve ser redirecionado para
   **`/installation/onboarding`**.
2. Crie a conta de **super admin** nessa tela. Esse caminho não depende de
   cadastro público estar habilitado (e ele já vem desabilitado, de propósito).
3. Faça login. Confira nos logs do serviço `sidekiq` que ele conectou ao Redis e
   está processando (sem `ECONNREFUSED` em loop).
4. **A prova de que o build usou o código deste fork:** o item **Kanban** aparece
   na barra lateral. Se você vê a sidebar do Chatwoot **sem** o item Kanban, a
   imagem oficial foi usada em vez do build — reveja o passo 4.
5. Abra o **Kanban**. O que você vê diz o que ainda falta:
   - **quadro com colunas** → tudo certo;
   - **"O Kanban Clínico não está configurado nesta instalação"** → as duas
     `VITE_FOCOH_*` não entraram no build. Marque como *Build Variable* e
     **refaça o deploy** (restart não resolve: o valor é gravado no bundle);
   - **"seu usuário não tem papel clínico atribuído"** → o build está certo e a
     conexão funciona. Falta atribuir o papel, no terminal do serviço `rails`:

```bash
bundle exec rails runner "u = User.first; u.update!(custom_attributes: u.custom_attributes.to_h.merge('focoh_clinical_role' => 'recepcao'))"
```

6. Antes de uso clínico real, aplique as migrations do Supabase e complete a
   checklist de validação clínica: [supabase/README.md](supabase/README.md).

> ⚠️ O limiar de risco e os destinatários do Protocolo Vermelho devem ser
> validados e assinados pela equipe clínica da Rede Focoh antes de produção.
> Um alerta que falha silenciosamente é um paciente sem socorro.

---

## 10. Troubleshooting

**Build morre com `Killed` ou `exit code 137`** — falta de memória. O build de
assets pede até ~4 GB. Aumente a RAM do servidor ou crie swap:

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

Para persistir após reboot, acrescente `/swapfile none swap sw 0 0` ao `/etc/fstab`.

**`extension "vector" is not available`** — o recurso Postgres está na imagem
oficial. Troque para `pgvector/pgvector:pg16` (passo 2). Trocar a imagem de um
banco já com dados exige cuidado: faça backup antes.

**Container `rails` em loop, logs repetindo `pg_isready`** — o entrypoint não
alcança o Postgres. Cheque, nesta ordem: o nome da variável é
`POSTGRES_USERNAME` (não `POSTGRES_USER`); o `POSTGRES_HOST` é o host **interno**
do Coolify; e os dois recursos estão na mesma rede/projeto.

**`sidekiq` não conecta / `Error connecting to Redis`** — revise a `REDIS_URL`.
O formato exige os dois-pontos antes da senha: `redis://:SENHA@host:6379`.
Confirme também `REDIS_PASSWORD`.

**Erro de `SECRET_KEY_BASE` no boot** — a variável não chegou ao container.
Algumas versões do Coolify não injetam automaticamente as env vars da UI nos
serviços de um Docker Compose. Se for o caso, acrescente os **nomes** ao
`environment:` do compose, sem valores — o Compose repassa do ambiente:

```yaml
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      INSTALLATION_ENV: docker
      SECRET_KEY_BASE:
      FRONTEND_URL:
      POSTGRES_HOST:
```

**502 / Bad Gateway, ou o domínio não resolve para o app** — o domínio precisa
estar no serviço **`rails`**, não no `sidekiq`, e o Coolify deve apontar para a
porta **3000** do container.

**CSS/JS faltando, tela quebrada** — o `assets:precompile` não concluiu. Procure
o erro nos logs de build; quase sempre é OOM (ver o primeiro item).

**Certificado não emite** — o registro A do DNS não estava propagado quando o
Coolify tentou. Confirme com `Resolve-DnsName` e mande reemitir.

**Kanban aparece mas o board fica vazio, sem mensagem de erro** — a RLS do
Supabase nega **por filtro, não por erro**. Confirme que as migrations de
`supabase/migrations/` foram aplicadas e que o papel clínico do usuário está na
lista aceita (`supabase/README.md` §3).

**Boot lento a cada restart** — esperado. `docker/entrypoints/rails.sh` roda
`bundle install` no boot; é comportamento do upstream, porque o entrypoint é
compartilhado com o compose de desenvolvimento. Exige rede no runtime.
